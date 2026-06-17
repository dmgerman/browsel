# Security audit

Audit of the current `browsel` Emacs module and bundled browser extension.
This review focuses on the default code paths in the repository.  Custom
Emacs handlers, user-edited extension handlers, or a different local Emacs
configuration can change the risk profile.

## Executive summary

I did not find direct arbitrary code execution in the default Emacs-side
handler set.  The module does not register a generic Elisp eval handler, and
the external tools it invokes (`pandoc`, `yt-dlp`) are called without going
through a shell.

The main default risks are:

- unauthenticated command triggering through the local WebSocket;
- unauthenticated page-to-Emacs request relay through `window.postMessage`;

The most important distinction: these are not default RCE findings.  Their
impact is mainly browser/Emacs side effects and network activity.

## Scope reviewed

Emacs Lisp:

- `browsel.el`
- `browsel-babel.el`
- `browsel-chatgpt.el`
- `browsel-tab-manager.el`
- `browsel-www.el`
- `browsel-youtube.el`

Browser extension:

- `extension/config.json`
- `extension/src/*.js`
- `extension/targets/chrome/src/*.js`
- `extension/targets/firefox/src/*.js`
- generated build layout enough to confirm build behavior

Validation run:

- `make lint` in `extension/` passed.
- `make` in `extension/` passed for Chrome and Firefox builds.
- `emacs -Q --batch -L . --eval '(require (quote browsel))'` could not run
  because the clean Emacs environment did not have the `websocket` package on
  its load path.
- `emacs -Q --batch -L . --eval '(byte-compile-file "browsel.el")'` likewise
  stopped at missing `websocket`.

## Impact categories

### Potential code execution

No direct arbitrary code execution was found in the default Emacs-side
handler set.

Relevant observations:

- Browser-to-Emacs handlers are named actions such as `ORG_CAPTURE`, `EWW`,
  `SAVE_PAGE`, `CHATGPT`, `YOUTUBE`, and `YOUTUBE_TRANSCRIPT`.
- There is no default WebSocket handler that evaluates arbitrary Elisp.
- `pandoc` and `yt-dlp` are invoked through `call-process` or
  `call-process-region`, not through a shell.
- `browsel-babel` can ask the browser to evaluate JavaScript, but that path is
  Emacs-initiated.  A web page cannot reach `EVAL_IN_ACTIVE_TAB` through the
  default page-to-Emacs relay because that handler lives on the browser side,
  not the Emacs side.

Indirect code-execution-like outcomes are still possible if:

- a user registers a custom Emacs handler that evaluates input;
- a user later evaluates unsafe Org content created from page-controlled text;
- a user follows unsafe Org links or has dangerous automatic Org behavior in
  their local configuration.

### Filesystem writes and persistent content

Medium impact.

The default handlers can write files under configured user directories:

- `SAVE_PAGE` writes HTML and Org archives under `browsel-www-archive-dir`.
- `CHATGPT` writes HTML and Org conversation archives under
  `browsel-chatgpt-dir`.
- `YOUTUBE_TRANSCRIPT` writes transcript Org/VTT files under
  `browsel-youtube-transcript-dir`.
- `YOUTUBE` appends an Org entry to `browsel-youtube-videos-file`.

The important risk is not arbitrary file write across the filesystem in the
normal case.  Page-controlled content is persisted under configured archive
locations by design.

### Browser and Emacs side effects

Low to medium impact.

Default handlers can:

- open URLs in EWW;
- focus/raise the Emacs frame when `:raise` is true;
- create Org capture buffers;
- write archive files;
- start metadata/transcript downloads.

These are meaningful side effects, but the defaults do not directly grant
arbitrary code execution.

### Network activity and local resource use

Low to medium impact.

Handlers can trigger:

- synchronous URL fetches for YouTube oEmbed/API metadata;
- `yt-dlp` transcript metadata and subtitle downloads;
- `pandoc` conversions of page-provided HTML;
- in-memory accumulation of whole WebSocket messages before JSON parsing.

This is primarily a denial-of-service/resource-exhaustion concern.

### Information disclosure

Low by default, medium if custom handlers are added.

The default Emacs-side handlers mostly return status messages and paths.  The
browser-side handlers can return tab metadata to Emacs (`GET_ALL_TABS`,
`GET_ACTIVE_TAB`) and can evaluate JavaScript after consent, but those are
Emacs-initiated capabilities.

## Findings

### 1. Local WebSocket has no authentication

Impact: unauthenticated local command triggering.

`browsel-start` starts a WebSocket server on `browsel-port` with
`browsel-host` defaulting to `local`.  `CLIENT_HELLO` checks client name and
version compatibility, but that is not authentication.  Any local process that
can connect to `127.0.0.1:9130` can send request frames to registered Emacs
handlers.

Default impact:

- trigger captures;
- open URLs in EWW;
- write archives/transcripts under configured directories;
- trigger network/tool work.

Not default impact:

- direct arbitrary Elisp execution.

Recommended mitigations:

- Be explicit in the threat model: a token stored where both Emacs and the
  browser extension can read it is not strong protection against a same-user
  local attacker.  That attacker can usually read the Emacs config, extension
  profile storage, filesystem, or process state as well.
- A per-session token can still be useful as defense in depth against
  accidental clients, confused local tooling, and cross-protocol/browser-origin
  attempts, but it should not be described as solving same-user local
  compromise.
- If the goal is stronger local-process isolation, rely on OS mechanisms:
  restrictive filesystem permissions, per-user browser profiles, platform
  credential storage where appropriate, firewall/socket policy, or simply keep
  the bridge disabled except when needed.
- If the `websocket` library exposes request headers, validate `Origin` as
  defense in depth.  This helps with browser-origin threats, not with arbitrary
  local processes.

### 2. Any web page can use the content-script relay

Impact: arbitrary web page can trigger browser-to-Emacs handlers.

`extension/src/content.js` listens for page `window.postMessage` events and
forwards any message shaped like:

```js
{ source: "browsel", name: "...", payload: ... }
```

The content script is installed on `<all_urls>`.  That means any site can ask
the extension to send a named request to Emacs.  This does not directly expose
browser-side `EVAL_IN_ACTIVE_TAB`, but it does expose registered Emacs-side
actions.

Default impact:

- create unwanted captures;
- open attacker-chosen URLs in EWW;
- write attacker-provided page/archive content;
- trigger YouTube transcript/download workflows;
- raise/focus Emacs if the payload includes `raise: true`.

Recommended fixes:

- Disable this relay by default.
- If keeping it, add an explicit origin allowlist.
- Require a capability token or nonce that pages cannot guess.
- Consider requiring a user gesture or extension option before enabling page
  relay for an origin.

## Positive security properties

- The Emacs server defaults to loopback rather than binding all interfaces.
- Browser-side JavaScript evaluation is gated by per-tab consent.
- Chrome additionally requires the user to enable "Allow User Scripts".
- Consent is cleared on tab close and can expire after one hour.
- Subprocess execution avoids shell interpolation.
- The extension build validates generated manifests and JS import resolution.
- Version mismatch between the extension and Emacs side is detected during
  `CLIENT_HELLO`.

## Recommended priority order

1. Disable or authenticate the page `postMessage` relay.
2. Clarify the local-process trust boundary.  Add token/origin checks only as
   defense in depth; do not present them as protection from a same-user local
   attacker who can read the same secrets.
