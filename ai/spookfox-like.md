# chrome-server: spookfox-like rewrite plan

Plan for rewriting `chrome-server` from a one-way HTTP service into a
bidirectional WebSocket bridge between Emacs and a Chrome (MV3) extension,
using ideas from the spookfox project as a source of inspiration.

## Reading guide (read these first)

All paths are relative to this module: `~/.emacs.d/modules/chrome-server/`.

| Path                                            | Read for                                                                 |
|-------------------------------------------------|--------------------------------------------------------------------------|
| `chrome-server.el`                              | Existing Emacs code being rewritten. Note the helpers, the dynamic payload cache (`chrome-server--current-url/title/text`), `chrome-server-org-capture-key`, and the respond-fast-then-defer pattern. |
| `chrome-server-www.el`, `-chatgpt.el`, `-youtube.el` | Existing per-feature backends. Same defservlet pattern, will become WS request handlers. |
| `README.org`                                    | Current architecture, endpoint catalog, configuration vars. Useful background, mostly obsolete after the rewrite. |
| `spookfox/lisp/spookfox.el`                     | Wire-protocol reference. **Adopt** the request/response shape and handler registry. **Do not adopt** the synchronous `sleep-for` polling — see "deliberately do not copy" below. |
| `spookfox/lisp/spookfox-tabs.el`                | Pattern for tab-manipulation requests on the Emacs side.                 |
| `spookfox/lisp/spookfox-js-injection.el`        | Pattern for JS-eval requests. Note `EVAL_IN_BACKGROUND_SCRIPT` is dropped. |
| `spookfox/spookfox-addon/src/background.js`     | MV2 reference for bidirectional protocol, `registerReqHandler`, `handleRequest`, reconnect loop, popup wiring. **Do not** copy MV2 specifics (`window.spookfox`, `tabs.executeScript({code})`, `'unsafe-eval'`). |
| `emacsProtocol/manifest.json`                   | Current MV3 manifest of the existing extension — uses `contextMenus`, `notifications`, `scripting`, `storage`, declares `commands`. New extension borrows heavily from this. |
| `emacsProtocol/background.js`, `popup.html/js`, `options.html/js`, `content-chatgpt.js` | Reference implementations for the current capabilities. Read before building the new extension to understand the user-facing behavior we must preserve. |

The two reference subdirectories (`spookfox/` and `emacsProtocol/`) live
inside this module for convenience. They are **not** to be modified —
they're frozen reference material.

## Source of ideas

The wire protocol and handler-registry concept come from the spookfox
Firefox MV2 extension. The implementation details — synchronous polling,
MV2 background page, `'unsafe-eval'` — are *not* copied. See the
"deliberately do not copy" section below for the full list.

## Why rewrite

Two concrete wins, both of which are blocked by the current HTTP design:

1. **Configurable menus.** Today, every context-menu item lives as hardcoded
   JavaScript in the extension. Adding a new action means editing
   `background.js` and reloading. After the rewrite, every menu entry —
   except the two hardcoded baseline actions — is just a row in a JSON
   config. New action = edit JSON, reload extension.

2. **Emacs can ask the browser for things.** HTTP only allows the browser
   to initiate; Emacs cannot get tab lists, focus a tab, or eval JS in a
   tab. A persistent duplex WebSocket fixes this, and a `handlers[]`
   section of the same config declares which `chrome.*` calls Emacs is
   allowed to invoke.

The combination gives one bidirectional bridge with one config file, where
new use cases require **no code changes** in either Emacs or the extension.

## Scope of change

- HTTP → WebSocket. Port `9129` → `9130`.
- `simple-httpd` dependency dropped on the Emacs side. Add `websocket`
  dependency (already used by the spookfox reference; install via
  `straight.el` if not present).
- All current endpoints (`/org-capture`, `/org-roam-capture`, `/eww`,
  `/save-page`, `/chatgpt`, `/youtube`) become WS request names.
- **Emacs side**: `chrome-server.el` and the per-feature backends
  rewritten in place.
- **Extension side**: a *new* extension is built from scratch in
  `./extension/`. The existing `./emacsProtocol/` directory is reference
  only — do not edit. The new extension ships with a `Makefile` that
  packages it (e.g. `make package` produces a zip suitable for
  `chrome://extensions` "Load unpacked" or Web Store submission; `make
  clean` removes artifacts; `make lint` validates `manifest.json` and
  `config.json`).
- Two hardcoded baseline menu items in the extension. Everything else
  becomes config-driven.

## Hardcoded extension features

Only the two universal Emacs operations are baked into the extension JS:

- `ORG_CAPTURE` — context-menu item "Emacs: org-capture from selection"
- `ORG_ROAM_CAPTURE` — context-menu item "Emacs: org-roam-capture from selection"

Rationale: these are the lingua franca of capturing things into Emacs and
should always be available regardless of config state or corruption. Every
other action (save-page, eww, chatgpt, youtube, user-defined) lives in
config.

### Must be preserved across the rewrite

The current `chrome-server.el` exposes two pieces of user-facing surface
that org-capture templates depend on. Both must continue to work after
the rewrite:

1. **`chrome-server-org-capture-key`** (defvar, currently line 56) — pins
   `/org-capture` to a specific template. `nil` means interactive
   selection. Keep the variable and its semantics.

2. **Dynamic payload cache** (currently lines 143–177) — the
   `chrome-server--current-url/title/text` vars and the
   `chrome-server-get-url`, `chrome-server-get-title`,
   `chrome-server-get-selection` accessors. These let org-capture
   templates pull payload fields via `%(chrome-server-get-url)` etc. The
   user's templates rely on this. The new handler for `ORG_CAPTURE` /
   `ORG_ROAM_CAPTURE` must set these vars before calling
   `org-capture`/`org-roam-capture` (same as today's
   `chrome-server--org-capture` at lines 179–190).

## Architecture

### Emacs side

- `websocket-server` on `127.0.0.1:9130`, started by
  `chrome-server-start`.
- Dispatcher splits incoming frames by presence of `:name`: request →
  registered handler; response → callback registry.
- **Async core from day one**: callback registry (`chrome-server--pending-callbacks`,
  alist keyed by request id) + `run-at-time` timeout per request.
  - Public API: `(chrome-server-request-async name payload callback)`.
  - Optional sync wrapper using `accept-process-output` for callers that
    want inline values (no `sleep-for` polling — spookfox's poll-based
    sync API is the cautionary example).
- Existing handlers keep their **respond-fast-then-defer** pattern:
  handler returns `((status . ok))` immediately, real work scheduled with
  `run-at-time` so the WS turnaround stays sub-millisecond.
- Files:
  - `chrome-server.el` — server lifecycle, dispatch, async primitive,
    org-capture / org-roam-capture / eww handlers.
  - `chrome-server-www.el` — `SAVE_PAGE` handler.
  - `chrome-server-chatgpt.el` — `CHATGPT` handler.
  - `chrome-server-youtube.el` — `YOUTUBE` handler.

### Extension side (MV3)

- **Offscreen document** holds the WebSocket. MV3 service workers idle out
  after ~30s, killing any WS they hold; offscreen documents don't. The
  service worker becomes a router between popup, content scripts, context
  menus, and the offscreen doc.
- **`chrome.userScripts.execute`** for the only JS-injection capability we
  keep (tab-context eval). Requires the user to enable "Allow User Scripts"
  per-extension in `chrome://extensions` — documented as a one-time setup.
  Default execution world: **`MAIN`** (sees the page's actual `window`,
  app state, page functions). `USER_SCRIPT` is available as an opt-in via
  the handler's `args-shape` adapter but is not the default — most spookfox
  use cases need page-state access.
- `EVAL_IN_BACKGROUND_SCRIPT` (spookfox's escape hatch) is **gone**. MV3
  forbids `'unsafe-eval'` in extension pages with no workaround that
  preserves `chrome.*` access. Replaced by declarative `handlers[]` entries
  that map names to `chrome.*` calls.
- Files (new, under `./extension/`):
  - `manifest.json` — MV3, declares `contextMenus`, `userScripts`,
    `offscreen`, `storage`, `notifications`, `scripting` (mirror what
    `./emacsProtocol/manifest.json` already declares), plus host
    permissions for `ws://localhost:9130/*`.
  - `background.js` (service worker) — router. No state of its own.
  - `offscreen.html` / `offscreen.js` — WS connection holder, reconnect
    loop, request/response correlation.
  - `content.js` — kept for the page-postMessage relay (spookfox-style
    hook for advanced users); minimal change.
  - `popup.html` / `popup.js` — connection status + manual reconnect.
    Reads status from offscreen doc via runtime messages.
  - `options.html` / `options.js` — edit a copy of `menus[]` and
    `handlers[]` in `chrome.storage.local`. Persist; trigger context-menu
    rebuild without requiring extension reload.
  - `content-chatgpt.js` — port the existing chatgpt content script
    unchanged (it's the only domain-specific content script).
  - `config.json` — bundled defaults.
  - `icon16.png`, `icon48.png`, `icon128.png` — copy from
    `./emacsProtocol/`.
  - `Makefile` — `make package` (zip the dir), `make clean`, `make lint`
    (validate `manifest.json` and `config.json` are well-formed).

## Wire protocol (spookfox-compatible)

JSON text frames over WebSocket. Two shapes, distinguished by which key
is present:

```json
// Request
{ "id": "<uuid>", "name": "ORG_CAPTURE", "payload": { ... } }

// Response
{ "requestId": "<uuid>", "payload": { ... } }
```

- Request names are SCREAMING_SNAKE_CASE.
- UUIDs correlate requests to responses; same on both sides.
- Error envelope inside response payload:
  `{ "status": "error", "message": "..." }`.
- 5-second timeout per outstanding request on both sides.

## Config schema (`config.json`)

```json
{
  "menus": [
    { "title": "Emacs: save page to archive",
      "trigger": "page",
      "request": "SAVE_PAGE",
      "source": "page-html",
      "raise": false },
    { "title": "Emacs: open in eww",
      "trigger": "page",
      "request": "EWW",
      "source": "page-url",
      "raise": true }
  ],
  "handlers": [
    { "name": "GET_ALL_TABS",
      "api":  "chrome.tabs.query",
      "args": {} },
    { "name": "FOCUS_TAB",
      "api":  "chrome.tabs.update",
      "args-from": "payload" },
    { "name": "EVAL_IN_ACTIVE_TAB",
      "api":  "chrome.userScripts.execute",
      "args-shape": "user-script" }
  ]
}
```

### Menu entry fields

| Field       | Meaning                                                  |
|-------------|----------------------------------------------------------|
| `title`     | Text shown in the context menu                           |
| `trigger`   | `page` \| `selection` \| `link` \| `image`               |
| `request`   | WS request name to send to Emacs                         |
| `source`    | What payload to gather: `page-url`, `page-html`, `selection-text`, `tab-info`, `link-url`, `image-url` |
| `raise`     | Optional; whether the request asks Emacs to take focus   |

### Handler entry fields

| Field        | Meaning                                                  |
|--------------|----------------------------------------------------------|
| `name`       | WS request name Emacs may send                           |
| `api`        | Dotted `chrome.*` path; resolved reflectively at runtime |
| `args`       | Static args object (literal)                             |
| `args-from`  | `payload` to pass payload through                        |
| `args-shape` | Named adapter for irregular APIs (e.g. `user-script`)    |

Reflective resolution (`chrome.tabs.query` via property access) is **not**
`eval` — it is plain JS and not blocked by MV3's CSP. The lookup table is
the manifest's declared permissions: if the API path is not permitted, the
call simply fails.

### Where config lives

1. **Bundled `config.json`** inside the extension — shipped defaults
   (save-page, eww, chatgpt, youtube menus; the standard handlers).
2. **`chrome.storage.local`** — user overrides written by the options page.
3. Service worker merges bundled + storage at startup and on storage
   changes; rebuilds `chrome.contextMenus` entries on every merge.

## What we adopt from spookfox

- Wire protocol shape (`id`/`name`/`payload`, `requestId`/`payload`).
- Request handler registry pattern (`registerReqHandler` on the browser;
  alist on the Emacs side).
- Reconnect loop (browser dials Emacs every 5s while disconnected).
- Popup connection-status UI (`CONNECTED` / `CONNECTING` / `DISCONNECTED`).
- Content-script `window.postMessage` → background relay (so web pages
  can trigger Emacs requests; one-line hook, kept).

## What we deliberately *do not* copy from spookfox

- **Synchronous `sleep-for` polling on the Emacs side.** spookfox blocks
  Emacs in 500ms quanta waiting for responses; we use a callback registry
  fired from the websocket's `:on-message` filter. No UI freeze, no
  500ms quantization, no leak from un-polled responses.
- **MV2 background page** with `window` global. The extension is MV3 from
  the start: offscreen document for the WS, service worker as router.
- **`EVAL_IN_BACKGROUND_SCRIPT`.** Cannot exist in MV3. Replaced by the
  declarative `handlers[]` registry.
- **Generic `EVAL_IN_TAB` with arbitrary code strings via
  `tabs.executeScript`.** Replaced by `chrome.userScripts.execute`, which
  requires the user-scripts toggle but is the MV3-sanctioned equivalent.

## What's lost vs current chrome-server

- HTTP debugging via `curl` is gone. Debugging becomes:
  - `*Messages*` buffer for Emacs-side errors.
  - Service worker DevTools (`chrome://extensions` → "Inspect views:
    service worker") and offscreen document DevTools for the JS side.
  - A `chrome-server-debug` flag that logs every frame to a `*chrome-server*`
    buffer (mirror of spookfox's `*spookfox*` debug buffer).
- Stateless per-request semantics gone. Replaced by persistent connection
  + automatic reconnect.
- Endpoints can no longer be hit from outside the extension. Anything
  that wanted that loses the entry point — a deliberate scope tightening.

## What's gained

- Emacs → browser direction: tab listing, focus, JS-in-tab eval, any
  `chrome.*` call declarable in `handlers[]`.
- Configurable menus without JS edits.
- One unified bridge instead of HTTP + (would-be) spookfox.
- Async-first Emacs API: no UI freezes, no leak, composable.

## Out of scope for v1

- **Codegen for handlers.** Runtime interpretation of `handlers[]` is
  enough. Revisit if expressiveness becomes a bottleneck.
- **Sandboxed-eval workarounds** to recover `EVAL_IN_BACKGROUND_SCRIPT`.
  The capability is gone; `handlers[]` covers the realistic use cases.
- **Multi-client support.** Treat the extension as the single client.
  If two browsers connect, last-wins routing is acceptable.
- **Backwards compatibility with HTTP.** Clean break. Anyone calling the
  old endpoints sees a "connection refused" until they update.

## Implementation order

1. Write this plan (this file).
2. Emacs: WebSocket server scaffolding (lifecycle, on-message dispatcher).
3. Emacs: async request primitive + callback registry + timeouts.
4. Emacs: port handlers (org-capture, org-roam-capture, eww, save-page,
   chatgpt, youtube). Keep respond-fast-then-defer pattern.
5. Extension: offscreen document with WS (reconnect loop, message
   dispatch, runtime-message bridge to service worker).
6. Extension: config loader + context menu builder. Two hardcoded
   menu entries (org-capture, org-roam-capture); the rest from config.
7. Extension: `handlers[]` dispatcher for Emacs-initiated requests.
   Reflective `chrome[api]` resolution; `chrome.userScripts.execute`
   adapter for JS-in-tab.
8. Extension: popup + options page updates.
9. End-to-end smoke test: load extension, start Emacs server, exercise
   one browser→Emacs flow (save-page from context menu) and one
   Emacs→browser flow (`GET_ALL_TABS` from `M-x`). Verify reconnect
   after Emacs restart, and that the offscreen doc survives past the
   30s service-worker idle window.

Each step lands as its own commit so the rewrite is reviewable in
manageable chunks.

## Project rules (from `~/.claude/CLAUDE.md` and `~/.emacs.d/CLAUDE.md`)

- **Never commit.** Tell the user when changes are ready; the user
  reviews and commits. This applies to every change, no exceptions.
- **Confirm before coding.** Before any non-trivial edit, describe the
  approach in one or two sentences and wait for the user's go-ahead.
- **Test changes via `emacsclient`.** Example:
  `emacsclient -e '(progn (load-file "~/.emacs.d/modules/chrome-server/chrome-server.el") (chrome-server-start))'`.
  Exit code 0 = success, 1 = error.
- **Functional style preferred.** Avoid mutation (`setq` on locals,
  `setcar`, etc.) where pure operations (`append`, `cons`, `mapcar`)
  work. Ask before introducing mutation.
- **No emojis** in code or commit messages unless explicitly requested.
- **Commit message style (when the user does commit)**: Linux-kernel
  style — imperative subject ≤72 chars, blank line, body wrapped at
  ~72 chars explaining *why*. See `~/.claude/CLAUDE.md` for the full
  rule.

## Current status and pick-up point

- Task #1 (this plan doc) — **complete**.
- Task #2 (Emacs WS scaffolding) — **next**. Start by rereading
  `chrome-server.el` to confirm the helpers that need to survive the
  rewrite (`--respond` becomes obsolete, `--parse-request` is replaced
  by JSON parsing of WS frames, `--maybe-raise` stays, the payload
  cache stays). Sketch the new dispatch loop before writing code, get
  the user's sign-off on the shape, then implement.
- Tasks #3–#9 — pending. See the implementation order section above
  for sequencing.

Task list is in the session's TaskList. If the fresh session sees the
tasks have been lost (new session, new task store), recreate them from
the "Implementation order" section.
