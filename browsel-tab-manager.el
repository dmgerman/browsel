;;; browsel-tab-manager.el --- Jump to a browser tab via completion  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; Author: Daniel M. German <dmg@turingmachine.org>
;; Assisted-by: Claude:claude-opus-4-7
;; Maintainer: Daniel M. German <dmg@turingmachine.org>
;; Keywords: comm, tools, browser
;; URL: https://github.com/dmgerman/browsel

;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Optional browsel module providing tab-management commands over
;; the browsel WebSocket bridge.  Two entry points:
;;
;;   `browsel-tab-jump'
;;     Completing-read jumper.  Reads a tab via the minibuffer and
;;     focuses it.  Each candidate renders as
;;     `[CLIENT ][asi] DOMAIN  TITLE' with separate faces per
;;     column.  In-prompt action keys:
;;       ?       help (legend + bindings)
;;       RET     focus the tab + window, exit
;;       M-RET   preview: show the tab in its window, stay in the prompt
;;       M-k     close the highlighted tab (see -confirm-close)
;;       C-c c   copy URL to the kill ring, stay in the prompt
;;       C-t     cycle sort: mru -> title -> domain -> window
;;     Both M-k and C-t preserve the typed filter on re-entry.
;;
;;   `browsel-tab-manager'
;;     Persistent buffer view backed by `tabulated-list-mode'.  Opens
;;     `*browsel-tab-manager*' with one line per tab across every
;;     connected browser.  Dired-style marking: `d' marks a tab for
;;     deletion, `x' executes marks, `D' closes the current tab
;;     immediately.  `RET' focuses the tab (does not close the
;;     buffer), `M-RET' previews without raising the browser window.
;;     `g' refreshes, `s' cycles sort, `w' copies the URL, `/'
;;     applies a regex filter, `= d' marks duplicates.  See
;;     `describe-mode' inside the buffer for the full binding list.
;;
;;   `browsel-tab-manager-close-duplicates'
;;     One-shot duplicate sweep.  URLs match after the `#fragment' is
;;     stripped; pinned tabs are skipped; the most-recently-accessed
;;     tab in each group is kept.  Confirms with a count before
;;     closing.
;;
;; `browsel-default-client' is intentionally ignored by both entry
;; points — every connected browser is always represented.  Pass an
;; explicit CLIENTS argument (or use the prefix arg on `browsel-tab-jump')
;; to restrict to a subset.
;;
;; User-tunable variables: `browsel-tab-manager-sort',
;; `browsel-tab-manager-confirm-close',
;; `browsel-tab-manager-domain-column-width',
;; `browsel-tab-manager-client-column-width'.  Faces:
;; `browsel-tab-manager-flags-face', `-client-face', `-domain-face',
;; `-title-face'.

;;; Code:

(require 'browsel)
(require 'url-parse)
(require 'cl-lib)
(require 'subr-x)
(require 'seq)

;; Soft-require: when consult is loaded we use `consult--read' so the
;; user's `consult-narrow-key' becomes the per-client filter shortcut.
;; When it isn't, we fall through to `completing-read' and the client
;; name in the display line is still typable as a filter.
(require 'consult nil t)
(declare-function consult--read "ext:consult" (table &rest options))
;; `consult--narrow' is bound buffer-locally by consult in the
;; minibuffer to the active narrow character (or nil when widened).
;; Our narrow predicate closes over it at read time; declaring it
;; special keeps the byte-compiler quiet when consult isn't loaded
;; at compile time.
(defvar consult--narrow)

;; Vertico is a hard dependency: the anchor-restore path (M-k) reads
;; `vertico--index' and `vertico--candidates' directly, so those
;; symbols must be resolvable at both compile and run time.
(require 'vertico)

;; ── Configuration ────────────────────────────────────────────────────────────

(defcustom browsel-tab-manager-domain-column-width 30
  "Width of the domain column in jump-to-tab completion candidates.
Domains longer than this are truncated with `…'; shorter ones get
padded with spaces so titles align across rows."
  :type 'integer
  :group 'browsel)

(defcustom browsel-tab-manager-client-column-width 10
  "Width of the client column in jump-to-tab completion candidates.
Only shown when two or more clients are connected; a single client
means the column is redundant noise and is suppressed.  Client names
longer than this width are truncated with `…' (e.g. a user label
`chrome-work-personal' → `chrome-wo…')."
  :type 'integer
  :group 'browsel)

(defcustom browsel-tab-manager-url-column-width 60
  "Width of the URL column in `browsel-tab-manager-mode' when URL view is on.
Toggled from the manager buffer with `v'; longer URLs are truncated
with `…'.  The narrower `browsel-tab-manager-domain-column-width' is
used when URL view is off (the default)."
  :type 'integer
  :group 'browsel)

(defcustom browsel-tab-manager-bookmark-function
  #'browsel-tab-manager-bookmark-default
  "Function called to save a bookmark for a browsel tab.
Called with two arguments — NAME (string) and TAB (plist as
returned by `browsel-browser-tabs') — and expected to register a
bookmark under NAME pointing at (plist-get TAB :url).  Return
value is ignored.

The default, `browsel-tab-manager-bookmark-default', stores a
vanilla `bookmark-store' record with `browse-url-bookmark-jump'
as the handler.  Users of `bookmark+' or another bookmark backend
can plug in their own function here without editing browsel."
  :type 'function
  :group 'browsel)

(defcustom browsel-tab-manager-sort 'mru
  "Default sort order for `browsel-tab-jump' and `browsel-tab-manager'.
Symbol values:
  mru     by `lastAccessed' descending (most-recently-used first)
  title   alphabetically by tab title
  domain  alphabetically by URL host
  window  by `windowId' then `index' (visual tab order per window)
The in-prompt `C-t' key cycles through these without leaving the
minibuffer."
  :type '(choice (const :tag "Most recently used" mru)
                 (const :tag "Title"               title)
                 (const :tag "Domain"              domain)
                 (const :tag "Window order"        window))
  :group 'browsel)

(defconst browsel-tab-manager--sort-cycle '(mru title domain window)
  "Order the `C-t' key steps through in jump-to-tab.")

(defcustom browsel-tab-manager-confirm-close t
  "Whether the in-prompt close key asks before closing a tab.
When non-nil, `M-k' inside `browsel-tab-jump' and `x' inside
`browsel-tab-manager' prompt with `yes-or-no-p' before issuing
CLOSE_TAB.  When nil, closures fire immediately.  The
buffer-view command `D' (immediate close of the current line)
bypasses this variable by design.  Has no effect on
`browsel-tab-manager-close-duplicates', which has its own
count-based confirmation."
  :type 'boolean
  :group 'browsel)

(defface browsel-tab-manager-flags-face
  '((t :inherit shadow))
  "Face for the `[asi]' flag prefix in jump-to-tab candidates."
  :group 'browsel)

(defface browsel-tab-manager-client-face
  '((t :inherit font-lock-type-face))
  "Face for the client column in jump-to-tab candidates.
Only rendered when two or more clients are connected."
  :group 'browsel)

(defface browsel-tab-manager-domain-face
  '((t :inherit font-lock-keyword-face))
  "Face for the domain column in jump-to-tab candidates."
  :group 'browsel)

(defface browsel-tab-manager-title-face
  '((t :inherit default))
  "Face for the title column in jump-to-tab candidates."
  :group 'browsel)

;; ── Candidate building ──────────────────────────────────────────────────────

(defun browsel-tab-manager--url-host (url)
  "Return the host of URL, or an empty string if it has none."
  (or (and (stringp url)
           (not (string-empty-p url))
           (ignore-errors (url-host (url-generic-parse-url url))))
      ""))

(defun browsel-tab-manager--flags (tab)
  "Return the bracketed flag prefix for TAB.
Three columns, lowercase letter if the flag is set, space otherwise:
  a — active (the focused tab in its window)
  s — sound (audible)
  i — incognito"
  (format "[%c%c%c]"
          (if (plist-get tab :active)    ?a ?\s)
          (if (plist-get tab :audible)   ?s ?\s)
          (if (plist-get tab :incognito) ?i ?\s)))

(defun browsel-tab-manager--display-base (tab show-client)
  "Return the propertized display string for TAB.
Format is `[CLIENT ]?[asi] DOMAIN  TITLE' where each segment carries
its own face (`browsel-tab-manager-client-face',
`browsel-tab-manager-flags-face',
`browsel-tab-manager-domain-face',
`browsel-tab-manager-title-face') so they are visually distinct.
The domain is padded or truncated to
`browsel-tab-manager-domain-column-width' so titles line up across
rows.  Two spaces separate the columns — a single space inside the
domain padding would blend with truncated-but-fits values.
SHOW-CLIENT non-nil prepends the tab's `:browsel-browser' name,
padded to `browsel-tab-manager-client-column-width'; when only one
client is connected the caller passes nil and the column is
suppressed entirely."
  (let* ((flags  (propertize (browsel-tab-manager--flags tab)
                             'face 'browsel-tab-manager-flags-face))
         (host   (browsel-tab-manager--url-host (plist-get tab :url)))
         (domain (propertize
                  (truncate-string-to-width
                   host browsel-tab-manager-domain-column-width
                   0 ?\s "…")
                  'face 'browsel-tab-manager-domain-face))
         (title  (propertize (or (plist-get tab :title) "(no title)")
                             'face 'browsel-tab-manager-title-face))
         (base   (concat flags " " domain "  " title)))
    (if show-client
        (let ((client (propertize
                       (truncate-string-to-width
                        (or (plist-get tab :browsel-browser) "?")
                        browsel-tab-manager-client-column-width
                        0 ?\s "…")
                       'face 'browsel-tab-manager-client-face)))
          (concat client " " base))
      base)))

(defun browsel-tab-manager--candidates (tabs show-client)
  "Return an alist of (DISPLAY . TAB) pairs for TABS.
DISPLAY is the propertized string from
`browsel-tab-manager--display-base'; bases that would collide
\(`equal' compares the underlying text only) get a propertized
\" (#ID)\" suffix in the flags face so each completion key is
unique without distorting the column alignment.  SHOW-CLIENT is
forwarded to `browsel-tab-manager--display-base'."
  (let ((bases (mapcar (lambda (tab)
                         (browsel-tab-manager--display-base tab show-client))
                       tabs)))
    (cl-mapcar
     (lambda (tab base)
       (cons (if (> (cl-count base bases :test #'equal) 1)
                 (concat base
                         (propertize (format " (#%s)" (plist-get tab :id))
                                     'face 'browsel-tab-manager-flags-face))
               base)
             tab))
     tabs bases)))

(defun browsel-tab-manager--sort-tabs (tabs sort)
  "Return TABS sorted according to SORT.
SORT is one of the symbols in `browsel-tab-manager--sort-cycle' —
`mru', `title', `domain', or `window'.  Unknown values pass TABS
through unchanged."
  (pcase sort
    ('mru
     (seq-sort-by (lambda (tab) (or (plist-get tab :lastAccessed) 0))
                  #'> tabs))
    ('title
     (seq-sort-by (lambda (tab)
                    (downcase (or (plist-get tab :title) "")))
                  #'string< tabs))
    ('domain
     (seq-sort-by (lambda (tab)
                    (downcase (browsel-tab-manager--url-host
                               (plist-get tab :url))))
                  #'string< tabs))
    ('window
     (seq-sort (lambda (a b)
                 (let ((wa (or (plist-get a :windowId) 0))
                       (wb (or (plist-get b :windowId) 0)))
                   (if (= wa wb)
                       (< (or (plist-get a :index) 0)
                          (or (plist-get b :index) 0))
                     (< wa wb))))
               tabs))
    (_ tabs)))

(defun browsel-tab-manager--next-sort (current)
  "Return the sort key that follows CURRENT in `--sort-cycle'."
  (let ((tail (cdr (memq current browsel-tab-manager--sort-cycle))))
    (or (car tail) (car browsel-tab-manager--sort-cycle))))

(defun browsel-tab-manager--completion-table (alist)
  "Return a completion table backed by ALIST that preserves entry order.
`completing-read' otherwise sorts candidates alphabetically; the
`display-sort-function' metadata tells modern completion frontends
\(vertico, icomplete, the default minibuffer) to keep the MRU order
the caller produced.

Note: no `group-function' metadata is set on purpose.  Vertico's
`vertico--group-by' reorders candidates so each group is
contiguous whenever `group-function' metadata is present — and
that reordering happens even with `vertico-group-format' bound to
nil (which only suppresses the visual headers).  That would
collapse cross-client MRU back into per-client MRU.  Narrowing to
one client belongs in the consult-integrated path, where the
per-tab `:browsel-browser' is read directly by a narrow predicate
that does not need group-function metadata."
  (lambda (string pred action)
    (if (eq action 'metadata)
        '(metadata (display-sort-function . identity)
                   (cycle-sort-function   . identity))
      (complete-with-action action alist string pred))))

;; ── Duplicate detection ────────────────────────────────────────────────────

(defun browsel-tab-manager--strip-url-hash (url)
  "Return URL with any `#...' fragment removed.
Query parameters are kept, so `?id=1' and `?id=2' remain distinct.
Two tabs at the same page but different anchors thus collapse to one."
  (if (and (stringp url) (string-match "\\`\\([^#]*\\)" url))
      (match-string 1 url)
    (or url "")))

(defun browsel-tab-manager--duplicate-victims (tabs)
  "Return the subset of TABS that a duplicate-tab sweep would close.
Pinned tabs are skipped entirely.  In each remaining group (keyed on
URL minus `#fragment') the tab with the highest `lastAccessed' is the
keeper; the others end up in the returned list."
  (let* ((live   (seq-remove (lambda (tab) (eq (plist-get tab :pinned) t))
                             tabs))
         (groups (seq-group-by
                  (lambda (tab)
                    (browsel-tab-manager--strip-url-hash
                     (plist-get tab :url)))
                  live))
         (dup    (seq-filter (lambda (g) (> (length (cdr g)) 1)) groups)))
    (apply #'append
           (mapcar (lambda (g)
                     (cdr (seq-sort-by
                           (lambda (tab) (or (plist-get tab :lastAccessed) 0))
                           #'>
                           (cdr g))))
                   dup))))

;; ── Public commands ─────────────────────────────────────────────────────────

(defun browsel-tab-manager--close-duplicates-in (client)
  "Compute duplicate victims for CLIENT and return (CLIENT VICTIMS...) plist.
Fetches CLIENT's tabs, applies `browsel-tab-manager--duplicate-victims',
and returns a plist so the caller can render a total and confirm
once across every client rather than prompting per browser."
  (let ((tabs (condition-case err
                  (browsel-request "GET_ALL_TABS" nil client)
                (error
                 (message "browsel-tab-manager: %s failed: %s"
                          client (error-message-string err))
                 nil))))
    (list :client client
          :victims (and tabs (browsel-tab-manager--duplicate-victims tabs)))))

;;;###autoload
(defun browsel-tab-manager-close-duplicates (&optional clients)
  "Close duplicate tabs in every connected browser, keeping the most recent.
Runs the duplicate sweep per client — two tabs at the same URL in
different browsers are not considered duplicates.  Two tabs are
duplicates when their URLs match after stripping any `#...' fragment;
query parameters (`?a=...') are preserved.  Pinned tabs are skipped —
never compared, never closed.  In each duplicate group the tab with
the highest `lastAccessed' is kept and the rest are closed.  Prompts
for confirmation once with a per-client breakdown of the counts
before closing anything.

CLIENTS narrows the sweep:
  - nil          — every connected browser.
  - name string  — that single browser only.
  - list of strings — every browser in the list.
Signals `user-error' when any requested name is not connected.

Interactively, a prefix argument prompts via `completing-read'
for a single browser; no prefix sweeps every connected browser.

Note: `chrome.tabs.remove' bypasses any in-page `beforeunload' prompt
\(those only fire from user-initiated UI closes\); pages with unsaved
form state close without a dialog.  Firefox behaves the same way."
  (interactive
   (list (browsel-tab-manager--maybe-prompt-client)))
  (let* ((clients (browsel--normalize-browsers clients))
         (plans   (mapcar #'browsel-tab-manager--close-duplicates-in clients))
         (total   (apply #'+ (mapcar
                              (lambda (p) (length (plist-get p :victims)))
                              plans)))
         (summary (mapconcat
                   (lambda (p)
                     (format "%s: %d"
                             (plist-get p :client)
                             (length (plist-get p :victims))))
                   plans ", ")))
    (cond
     ((zerop total)
      (message "browsel-tab-manager: no duplicate tabs (%s)" summary))
     ((not (y-or-n-p (format "Close %d duplicate tab(s) [%s]? "
                             total summary)))
      (message "browsel-tab-manager: aborted (would have closed %d)" total))
     (t
      (dolist (plan plans)
        (let* ((client   (plist-get plan :client))
               (victims  (plist-get plan :victims))
               (n        (length victims))
               (outcomes (mapcar
                          (lambda (tab)
                            (condition-case err
                                (progn
                                  (browsel-request "CLOSE_TAB"
                                                   (list :id (plist-get tab :id))
                                                   client)
                                  t)
                              (error
                               (message "Could not close tab %s (%s) in %s: %s"
                                        (plist-get tab :id)
                                        (plist-get tab :url)
                                        client
                                        (error-message-string err))
                               nil)))
                          victims)))
          (when (> n 0)
            (message "browsel-tab-manager: closed %d/%d duplicate tab(s) in %s"
                     (seq-count #'identity outcomes) n client))))))))


;; ── In-prompt action keys for jump-to-tab ──────────────────────────────────
;;
;; While `browsel-tab-jump' is reading a candidate the
;; following keys operate on the highlighted candidate:
;;
;;   ?       show a one-shot help buffer with the legend + bindings
;;   C-c c   copy the candidate's URL to the kill ring (stay in prompt)
;;   M-k     close the candidate's tab and stay in the prompt
;;   RET     focus the tab and exit (default)
;;
;; Both action keys are side-effect-only and do not exit the
;; minibuffer.  The closed tab stays in the in-memory candidate list
;; for the lifetime of the prompt — picking it after closure will
;; simply fail when FOCUS_TAB cannot find it.

(defvar browsel-tab-manager--current-alist nil
  "Dynamic binding: alist of (DISPLAY . TAB) for the active prompt.
Bound by `browsel-tab-jump' for the duration of the
`completing-read' call so the in-prompt action commands can look up
the tab plist that backs the highlighted display string.")

(defvar browsel-tab-manager--current-sort nil
  "Dynamic binding: sort key the active prompt is showing.
Used by `browsel-tab-jump-cycle-sort' to compute the next
sort key without re-reading `browsel-tab-manager-sort' (which is the
default, not the current state).")

(defun browsel-tab-manager--current-display ()
  "Return the display string of the highlighted completion candidate.
Prefers `vertico--candidate' when Vertico is the active frontend in
this minibuffer (detected via `bound-and-true-p' on its buffer-local
marker, since the defvar is bound globally), then the first entry of
the variable `completion-all-sorted-completions' (Icomplete and default cycle),
and finally falls back to the typed minibuffer contents passed
through `try-completion'."
  (cond
   ((and (fboundp 'vertico--candidate)
         (bound-and-true-p vertico--input))
    (vertico--candidate))
   ((and (boundp 'completion-all-sorted-completions)
         completion-all-sorted-completions)
    (car completion-all-sorted-completions))
   (t (let* ((input (minibuffer-contents-no-properties))
             (m     (and minibuffer-completion-table
                         (try-completion input
                                         minibuffer-completion-table))))
        (cond ((stringp m) m)
              ((eq m t)    input)
              (t           input))))))

(defun browsel-tab-manager--current-tab ()
  "Return the tab plist for the highlighted candidate, or nil."
  (let ((display (browsel-tab-manager--current-display)))
    (and (stringp display)
         (cdr (assoc display browsel-tab-manager--current-alist)))))

(defun browsel-tab-jump-help ()
  "Show in-prompt help for `browsel-tab-jump'."
  (interactive)
  (with-help-window "*browsel-tab-jump help*"
    (princ "browsel-tab-jump — jump-to-tab in-prompt actions\n")
    (princ "\n")
    (princ "  Flag prefix [asi]:\n")
    (princ "    a — active tab in its window\n")
    (princ "    s — sound (audible)\n")
    (princ "    i — incognito\n")
    (princ "  Trailing (#ID) appears only when two tabs would render to\n")
    (princ "  the same display; the numeric tab id disambiguates them.\n")
    (princ "\n")
    (princ "  Action keys (operate on the highlighted candidate):\n")
    (princ "    ?       this help\n")
    (princ "    C-c c   copy URL to the kill ring (stay in prompt)\n")
    (princ "    M-k     close the tab and stay in the prompt\n")
    (princ "    M-RET   show the tab in Chrome without raising the window\n")
    (princ "            (preview — stay in the prompt, Emacs keeps focus)\n")
    (princ "    C-t     cycle sort order (mru -> title -> domain -> window)\n")
    (princ "    RET     focus the tab + window, exit the prompt\n")))

(defun browsel-tab-jump-show-tab ()
  "Make the highlighted tab the active tab in its browser window.
Calls `FOCUS_TAB' without `:focusWindow' so the tab becomes visible
inside its browser but the OS-level window is not raised — Emacs
keeps focus.  The request is routed to the tab's own
`:browsel-browser', so this works uniformly whether the highlighted
row came from Chrome or Firefox.  After the FOCUS_TAB call the
prompt re-enters with fresh tabs so the `[a]' flag reflects the
new active tab; the highlight stays on the shown candidate and any
typed filter is preserved."
  (interactive)
  (let ((tab (browsel-tab-manager--current-tab)))
    (if (null tab)
        (message "No candidate selected")
      (condition-case err
          (progn
            (browsel-request "FOCUS_TAB"
                             `(:id ,(plist-get tab :id))
                             (plist-get tab :browsel-browser))
            (throw 'browsel-tab-manager--cycle
                   (list :sort   browsel-tab-manager--current-sort
                         :input  (minibuffer-contents-no-properties)
                         :anchor (plist-get tab :id))))
        (error
         (message "Could not show %s: %s"
                  (plist-get tab :title)
                  (error-message-string err)))))))

(defun browsel-tab-jump-copy-url ()
  "Copy the highlighted candidate's tab URL to the kill ring."
  (interactive)
  (let* ((tab (browsel-tab-manager--current-tab))
         (url (and tab (plist-get tab :url))))
    (if (and (stringp url) (not (string-empty-p url)))
        (progn (kill-new url)
               (message "Copied: %s" url))
      (message "No candidate selected"))))

(defun browsel-tab-jump-cycle-sort ()
  "Re-open the jump-to-tab prompt under the next sort key.
Signals the outer wrapper via `throw' so the prompt re-enters with
fresh tabs, the next sort from `browsel-tab-manager--sort-cycle',
and the typed-text preserved as the initial input — your filter
survives the cycle."
  (interactive)
  (throw 'browsel-tab-manager--cycle
         (list :sort   (browsel-tab-manager--next-sort
                        browsel-tab-manager--current-sort)
               :input  (minibuffer-contents-no-properties)
               :anchor nil)))

(defun browsel-tab-jump-close-tab ()
  "Close the highlighted candidate's tab.
Honours `browsel-tab-manager-confirm-close': when non-nil prompts
with `yes-or-no-p' and leaves you in the prompt afterwards (so a
deliberate close is followed by a stable candidate view).  When
nil the closure fires immediately and the prompt is re-entered
with a fresh `GET_ALL_TABS' under the current sort so the closed
tab is gone from the list — chains of `M-k' without typed text
land cleanly.

The re-entry signal is a `throw' to `browsel-tab-manager--cycle';
the catch in `browsel-tab-manager--run-prompt' receives the
current sort key and tail-recurses."
  (interactive)
  (let ((tab (browsel-tab-manager--current-tab)))
    (cond
     ((null tab)
      (message "No candidate selected"))
     ((and browsel-tab-manager-confirm-close
           (not (yes-or-no-p (format "Close tab: %s? "
                                     (plist-get tab :title)))))
      (message "Close aborted"))
     (t
      (condition-case err
          (progn
            (browsel-request "CLOSE_TAB"
                             `(:id ,(plist-get tab :id))
                             (plist-get tab :browsel-browser))
            (unless browsel-tab-manager-confirm-close
              (throw 'browsel-tab-manager--cycle
                     (list :sort   browsel-tab-manager--current-sort
                           :input  (minibuffer-contents-no-properties)
                           :anchor (browsel-tab-manager--anchor-above-id)))))
        (error
         (message "Could not close %s: %s"
                  (plist-get tab :title)
                  (error-message-string err))))))))

(defconst browsel-tab-manager--jump-bindings
  '(("?"     . browsel-tab-jump-help)
    ("C-c c" . browsel-tab-jump-copy-url)
    ("M-k"   . browsel-tab-jump-close-tab)
    ("M-RET" . browsel-tab-jump-show-tab)
    ("C-t"   . browsel-tab-jump-cycle-sort))
  "Single source of truth for jump-to-tab in-prompt keys.
Installed onto whatever local map the active completion frontend
\(vertico, icomplete, default) provides; see
`browsel-tab-manager--install-keys'.")

(defun browsel-tab-manager--install-keys ()
  "Add the in-prompt action keys to the current minibuffer's local map.
Earlier code composed `browsel-tab-jump-map' on top of the
frontend's map via `make-composed-keymap', but that diverted RET
lookups through the wrong fallback chain (the user's typed input
came back empty).  Copying the active local map and inserting our
bindings into the copy keeps the frontend's bindings intact and
co-located with ours."
  (let ((map (copy-keymap (current-local-map))))
    (dolist (binding browsel-tab-manager--jump-bindings)
      (define-key map (kbd (car binding)) (cdr binding)))
    (use-local-map map)))

(defun browsel-tab-manager--anchor-above-id ()
  "Return the `:id' of the tab one row above the highlighted one.
Reads vertico's index/candidates and resolves the row above to a tab
plist via `browsel-tab-manager--current-alist'.  The id is the stable
identity used by the re-entered prompt to relocate the highlight
even when the candidate's display string has changed (e.g. the
`[a]' flag flipped).  Returns nil outside vertico or when no row is
above."
  (when (and (bound-and-true-p vertico--input)
             (boundp 'vertico--index)
             (boundp 'vertico--candidates))
    (let ((idx vertico--index))
      (when (and (numberp idx) vertico--candidates (>= idx 1))
        (let ((display (nth (1- idx) vertico--candidates)))
          (plist-get (cdr (assoc display
                                 browsel-tab-manager--current-alist))
                     :id))))))

(defun browsel-tab-manager--jump-to-anchor (anchor-id)
  "Move vertico's highlight to the candidate whose tab has ANCHOR-ID.
ANCHOR-ID is a tab `:id'.  We look it up in the freshly-built
candidate alist to recover the (possibly changed) display string,
then locate that string in vertico's current candidates.  Runs as a
0-timer so it fires after vertico's first refresh.  No-ops outside
vertico, or when the tab is no longer present, or when the typed
filter has excluded it."
  (when anchor-id
    (run-at-time
     0 nil
     (lambda ()
       (when (and (bound-and-true-p vertico--input)
                  (fboundp 'vertico--goto)
                  (boundp 'vertico--candidates)
                  vertico--candidates)
         (let* ((entry (seq-find
                        (lambda (e)
                          (equal anchor-id
                                 (plist-get (cdr e) :id)))
                        browsel-tab-manager--current-alist))
                (display (and entry (car entry)))
                (idx (and display
                          (cl-position display
                                       vertico--candidates
                                       :test #'equal))))
           (when (and idx (>= idx 0))
             (vertico--goto idx))))))))

;; ── Consult narrowing (optional) ───────────────────────────────────────────
;;
;; When consult is loaded, the tab prompt goes through `consult--read'
;; with a `:narrow' config so the user's `consult-narrow-key' (e.g.
;; `C-=') filters candidates to one client with a single keystroke.
;; The narrow predicate reads `:browsel-browser' directly from each
;; tab plist, so no group-function metadata is exposed to the
;; completion machinery — vertico only reorders candidates
;; contiguously by group when it sees `group-function' metadata, and
;; that reordering would collapse cross-client MRU into per-client
;; MRU regardless of `vertico-group-format'.  The per-row client
;; column already tells the user which browser owns each tab.

(defun browsel-tab-manager--narrow-config (clients)
  "Build a narrow spec for CLIENTS as a plist.
Returns `(:config ((KEY . CLIENT) ...) :unreachable (CLIENT ...))'.
KEY is the first character of CLIENT.  When two clients share a
first character, the earlier one keeps the key and the later one
lands in `:unreachable' — the caller warns so the user can rename
their label or accept that narrowing is one-key coverage."
  (seq-reduce
   (lambda (acc client)
     (let ((key     (and (stringp client)
                         (> (length client) 0)
                         (aref client 0)))
           (config  (plist-get acc :config))
           (unreach (plist-get acc :unreachable)))
       (cond
        ((null key)         acc)
        ((assq key config)  (list :config config
                                  :unreachable (append unreach (list client))))
        (t                  (list :config (append config
                                                  (list (cons key client)))
                                  :unreachable unreach)))))
   clients
   (list :config nil :unreachable nil)))

(defun browsel-tab-manager--read-tab (prompt alist initial-input clients setup-fn)
  "Read a tab display string, using consult when available.
PROMPT and INITIAL-INPUT are passed through to the underlying
reader.  ALIST is the (DISPLAY . TAB) alist that also backs the
completion table.  CLIENTS is the list of client names represented
in ALIST; used to build the narrow spec.  SETUP-FN runs inside
`minibuffer-with-setup-hook'.  Returns the picked display string,
or nil on quit.

The consult path deliberately omits `:group' so vertico does not
reorder candidates by client — global MRU survives.  Narrowing
uses a predicate that reads `:browsel-browser' from each tab
plist, so it works without group-function metadata."
  (let ((table (browsel-tab-manager--completion-table alist)))
    (if (fboundp 'consult--read)
        (let* ((cfg      (browsel-tab-manager--narrow-config clients))
               (keys     (plist-get cfg :config))
               (unreach  (plist-get cfg :unreachable))
               ;; Consult calls this on each candidate while narrowing
               ;; is active.  `consult--narrow' holds the active char
               ;; (e.g. ?c); we look up its client name in KEYS and
               ;; keep candidates whose tab belongs to it.
               ;;
               ;; CAND's shape depends on how the completion machinery
               ;; enumerates the alist: `complete-with-action' passes
               ;; each entry as a (DISPLAY . TAB) cons, while some
               ;; frontends flatten to just the display string.
               ;; Handle both so the predicate is robust to either
               ;; path.  Consult disables the predicate when
               ;; narrowing is widened, so we never see nil narrow.
               ;;
               ;; The predicate reads `:browsel-browser' directly from
               ;; the tab plist — no dependency on group-function
               ;; metadata.  That is deliberate: setting `:group' on
               ;; the consult--read call would make vertico's
               ;; `vertico--group-by' re-order candidates so each
               ;; client is contiguous (see vertico.el:289), which
               ;; would break the global MRU sort.
               ;; `vertico-group-format' only hides the group
               ;; headers; it does not disable the reordering.  So
               ;; the fix is not to set `:group' at all.
               (narrow-pred
                (lambda (cand)
                  (let ((tab (cond ((consp cand)   (cdr cand))
                                   ((stringp cand) (cdr (assoc cand alist))))))
                    (and tab
                         (equal (plist-get tab :browsel-browser)
                                (alist-get consult--narrow keys)))))))
          (when unreach
            (message
             "browsel-tab-manager: no narrow key for %s \
\(first-letter collision); rename the client label to distinguish"
             (mapconcat #'identity unreach ", ")))
          (minibuffer-with-setup-hook (:append setup-fn)
            (consult--read table
                           :prompt        prompt
                           :require-match t
                           :sort          nil
                           :initial       (and (stringp initial-input)
                                               (not (string-empty-p initial-input))
                                               initial-input)
                           :narrow        (list :keys keys
                                                :predicate narrow-pred)
                           :category      'browsel-tab)))
      (minibuffer-with-setup-hook (:append setup-fn)
        (completing-read prompt table nil t
                         (and (stringp initial-input)
                              (not (string-empty-p initial-input))
                              initial-input))))))

(defun browsel-tab-manager--run-prompt (sort &optional initial-input anchor clients)
  "Run one jump-to-tab prompt under SORT across the selected clients.
Each call fetches a fresh `GET_ALL_TABS' so closures and reorderings
between prompts (e.g. after `M-k') are reflected immediately.  Each
row's `:browsel-browser' names the browser it came from — actions
route back to it, so a mixed Chrome/Firefox prompt Just Works.  The
client column is rendered only when two or more clients are
represented in the current result.

INITIAL-INPUT, when a non-empty string, pre-fills the minibuffer.
ANCHOR, when a non-nil tab id, becomes the candidate the highlight
lands on after vertico has refreshed — used by `M-k' to keep the
user one row above where the closed tab was.  CLIENTS, when
non-nil, restricts the prompt: nil aggregates every connected
client; a string names one; a list of strings names several.
When `M-k' or `C-t' throw, the in-prompt command sends a plist
\(:sort :input :anchor) to `browsel-tab-manager--cycle' and this
function tail-recurses with it, carrying CLIENTS along so the
restriction persists across cycles; otherwise it focuses the
chosen tab and returns."
  (let* ((tabs (browsel-browser-tabs clients)))
    (unless tabs
      (user-error "Browsel-tab-manager: no tabs returned from any client"))
    (let* ((clients      (delete-dups
                          (mapcar (lambda (tab) (plist-get tab :browsel-browser))
                                  tabs)))
           (show-client  (> (length clients) 1))
           (sorted       (browsel-tab-manager--sort-tabs tabs sort))
           (alist        (browsel-tab-manager--candidates sorted show-client))
           (browsel-tab-manager--current-alist alist)
           (browsel-tab-manager--current-sort  sort)
           (setup-fn (lambda ()
                       (browsel-tab-manager--install-keys)
                       (browsel-tab-manager--jump-to-anchor anchor)))
           (prompt   (format "Tab [%s] (%s): "
                             sort
                             (mapconcat #'identity clients ", ")))
           (next
            ;; `catch' captures the non-local-exit signals from the
            ;; in-prompt action commands (M-k / M-RET / C-t); errors
            ;; raised inside the body go through the inner
            ;; `condition-case' and are reported explicitly so the
            ;; user always sees what went wrong rather than relying
            ;; on Emacs's top-level handler.
            (catch 'browsel-tab-manager--cycle
              (condition-case err
                  (let* ((pick (browsel-tab-manager--read-tab
                                prompt alist initial-input clients setup-fn))
                         ;; Some completion frontends strip text
                         ;; properties on exit (vertico) while others
                         ;; preserve them; look up under both.
                         (key  (and (stringp pick)
                                    (substring-no-properties pick)))
                         (tab  (or (cdr (assoc key  alist))
                                   (cdr (assoc pick alist))))
                         (client (and tab (plist-get tab :browsel-browser))))
                    (unless tab
                      (user-error "Browsel-tab-manager: no tab matches %S"
                                  pick))
                    (browsel-request "FOCUS_TAB"
                                     `(:id ,(plist-get tab :id) :focusWindow t)
                                     client)
                    (browsel-activate-client client)
                    nil)
                (error
                 (message "browsel-tab-manager: %s"
                          (error-message-string err))
                 nil)))))
      (when (browsel-tab-manager--valid-next-p next)
        (browsel-tab-manager--run-prompt (plist-get next :sort)
                                         (plist-get next :input)
                                         (plist-get next :anchor)
                                         clients)))))

(defun browsel-tab-manager--valid-next-p (next)
  "Return non-nil when NEXT is a plist shaped like our throw protocol.
Belt-and-suspenders: ensures a stray `throw' to our tag with the
wrong payload cannot send the prompt loop recursing with junk.
Checks that NEXT is a non-empty list whose first element is a
keyword and that contains a `:sort' key our sort cycle recognizes."
  (and (listp next)
       next
       (keywordp (car next))
       (memq (plist-get next :sort) browsel-tab-manager--sort-cycle)))

;;;###autoload
(defun browsel-tab-jump (&optional clients)
  "Focus a tab in any connected browser, picked via completion.
By default, aggregates tabs from every entry in
`browsel-connected-clients' into one list —
`browsel-default-client' is intentionally ignored so the
interactive command always shows everything.  When two or more
clients are represented, each row starts with a client column so
the origin browser is visible at a glance; the consult path
offers `consult-narrow' so a single keystroke filters the prompt
to one browser.

CLIENTS narrows the tab list:
  - nil          — aggregate every connected client (interactive default).
  - name string  — that single browser only.
  - list of strings — every browser in the list.
Client names are session-unique — see `browsel-clients-file' for
the persistence that keeps them stable across Emacs restarts —
so passing one or several is a deterministic selector.  Signals
`user-error' when any requested name is not connected.

Interactively, a prefix argument prompts via `completing-read'
for a single browser from `browsel-connected-clients'; no prefix
aggregates all.

The initial sort order comes from `browsel-tab-manager-sort'
\(default `mru'); use `C-t' inside the prompt to cycle through
mru / title / domain / window orders.  RET focuses the chosen tab
and its parent window via the extension's FOCUS_TAB handler —
routed to whichever client that tab came from.

In-prompt keys (see also `?' inside the prompt):
  ?       legend + action-key help
  \\[browsel-tab-jump-copy-url]   copy the highlighted candidate's URL to the kill ring
  \\[browsel-tab-jump-close-tab]     close the highlighted candidate's tab and stay in the prompt
  \\[browsel-tab-jump-show-tab]   show the highlighted tab in its browser without raising the window
  \\[browsel-tab-jump-cycle-sort]     cycle the sort order"
  (interactive
   (list (browsel-tab-manager--maybe-prompt-client)))
  (browsel-tab-manager--run-prompt browsel-tab-manager-sort nil nil clients))

(defun browsel-tab-manager--maybe-prompt-client ()
  "Return a client name (via `completing-read') when a prefix arg is active.
No prefix returns nil so callers aggregate every connected client.
Signals `user-error' when no client is connected in the prefix
path.  Does not consult `browsel-default-client' — the tab
manager is aggregation-by-default and the prompt is an explicit
narrowing gesture."
  (when current-prefix-arg
    (let ((connected (browsel-connected-clients)))
      (unless connected
        (user-error "Browsel-tab-manager: no client connected"))
      (completing-read "Browser: " connected nil t nil nil
                       (car connected)))))

;; ── Buffer-view tab manager (tabulated-list-mode) ──────────────────────────
;;
;; `browsel-tab-manager' opens a persistent *browsel-tab-manager* buffer
;; with one line per open tab, dired-style marking, and the same sort
;; keys the jump command exposes.  The mark tag lives in the
;; `tabulated-list-padding' area (not a format column), so the layout
;; matches the jumper's per-row rendering plus a two-character mark
;; prefix.

(defvar-local browsel-tab-manager--tabs nil
  "Alist mapping `tabulated-list-id' → tab plist for the current buffer.
The id is a cons of the tab's browsel-instance UUID and its numeric
tab id; that pair is unique across every connected browser and stable
across refreshes.")

(defvar-local browsel-tab-manager--filter nil
  "Regex applied at refresh time; only tabs whose title, URL, or domain
matches survive.  nil means no filter.")

(defvar-local browsel-tab-manager--buffer-sort nil
  "Current sort key for this buffer.
Falls back to `browsel-tab-manager-sort' when nil.  Advanced via
`s' or by cycling from the header row.")

(defvar-local browsel-tab-manager--show-url nil
  "When non-nil, the buffer shows each tab's full URL instead of just the domain.
Toggled by `v'.")

(defun browsel-tab-manager--row-id (tab)
  "Return the tabulated-list-id key for TAB."
  (cons (or (plist-get tab :browsel-instance) "?") (plist-get tab :id)))

(defun browsel-tab-manager--tab-matches-filter-p (tab regex)
  "Return non-nil when TAB's title, url, or domain matches REGEX."
  (let ((title  (or (plist-get tab :title) ""))
        (url    (or (plist-get tab :url)   ""))
        (domain (browsel-tab-manager--url-host (plist-get tab :url))))
    (or (string-match-p regex title)
        (string-match-p regex url)
        (string-match-p regex domain))))

(defun browsel-tab-manager--format-columns (show-client show-url)
  "Return the `tabulated-list-format' vector.
Includes a Client column iff SHOW-CLIENT (two or more connected
browsers represented in the current view).  When SHOW-URL is
non-nil, the Domain column becomes a URL column widened to
`browsel-tab-manager-url-column-width'."
  (let* ((location-col
          (if show-url
              (list "URL" browsel-tab-manager-url-column-width t)
            (list "Domain" browsel-tab-manager-domain-column-width t)))
         (rest (vector '("Flags" 5 nil)
                       location-col
                       '("Title" 0 t))))
    (if show-client
        (apply #'vector
               (list "Client" browsel-tab-manager-client-column-width t)
               (append rest nil))
      rest)))

(defun browsel-tab-manager--build-entries (tabs show-client show-url)
  "Return `tabulated-list-entries' rows for TABS.
SHOW-CLIENT prepends the browser column; SHOW-URL renders the full
URL (truncated to `browsel-tab-manager-url-column-width') instead of
just the hostname."
  (mapcar
   (lambda (tab)
     (let* ((flags    (propertize (browsel-tab-manager--flags tab)
                                  'face 'browsel-tab-manager-flags-face))
            (url      (or (plist-get tab :url) ""))
            (location (propertize
                       (if show-url
                           (truncate-string-to-width
                            url browsel-tab-manager-url-column-width
                            0 ?\s "…")
                         (or (browsel-tab-manager--url-host url) ""))
                       'face 'browsel-tab-manager-domain-face))
            (title    (propertize (or (plist-get tab :title) "(no title)")
                                  'face 'browsel-tab-manager-title-face))
            (client   (propertize (or (plist-get tab :browsel-browser) "?")
                                  'face 'browsel-tab-manager-client-face)))
       (list (browsel-tab-manager--row-id tab)
             (if show-client
                 (vector client flags location title)
               (vector flags location title)))))
   tabs))

(defun browsel-tab-manager--refresh (&rest _)
  "Fetch tabs, apply the buffer filter and sort, and repopulate the buffer.
Preserves point on the same row-id when the tab still exists after
refresh.  Called from `revert-buffer' (bound to `g' by
`tabulated-list-mode') and from every action that changes tab
state (execute, immediate close, filter change, sort cycle, URL
toggle)."
  (let* ((raw       (browsel-browser-tabs))
         (filter    browsel-tab-manager--filter)
         (show-url  browsel-tab-manager--show-url)
         (kept      (if filter
                        (seq-filter (lambda (tab)
                                      (browsel-tab-manager--tab-matches-filter-p
                                       tab filter))
                                    raw)
                      raw))
         (sort-key  (or browsel-tab-manager--buffer-sort
                        browsel-tab-manager-sort))
         (sorted    (browsel-tab-manager--sort-tabs kept sort-key))
         (clients   (delete-dups
                     (mapcar (lambda (tab) (plist-get tab :browsel-browser))
                             sorted)))
         (show-c    (> (length clients) 1))
         (target    (tabulated-list-get-id)))
    (setq browsel-tab-manager--tabs
          (mapcar (lambda (tab)
                    (cons (browsel-tab-manager--row-id tab) tab))
                  sorted))
    (setq tabulated-list-format
          (browsel-tab-manager--format-columns show-c show-url))
    (setq tabulated-list-sort-key nil)  ; we sort ourselves
    (setq tabulated-list-entries
          (browsel-tab-manager--build-entries sorted show-c show-url))
    (tabulated-list-init-header)
    (tabulated-list-print t)
    (when target
      (goto-char (point-min))
      (while (and (not (eobp))
                  (not (equal (tabulated-list-get-id) target)))
        (forward-line 1))
      (when (eobp) (goto-char (point-min))))
    ;; Header line: always-visible glanceable status.  Sort key is
    ;; the primary signal; filter and URL-view are called out only
    ;; when active so the header stays terse in the common case.
    (setq header-line-format
          (concat
           (propertize " Sort: " 'face 'shadow)
           (propertize (symbol-name sort-key) 'face 'bold)
           (when show-url
             (concat (propertize "  |  " 'face 'shadow)
                     (propertize "URL view" 'face 'font-lock-keyword-face)))
           (when filter
             (concat (propertize "  |  Filter: " 'face 'shadow)
                     (propertize (format "/%s/" filter)
                                 'face 'font-lock-warning-face)))
           (when (and clients (not show-c))
             (concat (propertize "  |  " 'face 'shadow)
                     (propertize (car clients)
                                 'face 'browsel-tab-manager-client-face)))
           (propertize
            (format "  |  %d tab%s"
                    (length sorted)
                    (if (= (length sorted) 1) "" "s"))
            'face 'shadow)))
    ;; Keep mode-name short — the header-line carries the detail.
    (setq mode-name (format "Tabs[%s]" sort-key))
    (force-mode-line-update)))

(defun browsel-tab-manager--tab-at-point ()
  "Return the tab plist for the row point is on, or nil."
  (cdr (assoc (tabulated-list-get-id) browsel-tab-manager--tabs)))

;; ── Actions ────────────────────────────────────────────────────────────────

(defun browsel-tab-manager-mark-delete (&optional _arg)
  "Mark the tab on the current line for deletion and advance one line."
  (interactive "p")
  (tabulated-list-put-tag "D" t))

(defun browsel-tab-manager-unmark (&optional _arg)
  "Clear the mark on the tab on the current line and advance one line."
  (interactive "p")
  (tabulated-list-put-tag " " t))

(defun browsel-tab-manager-unmark-all ()
  "Clear marks from every tab in the buffer."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (tabulated-list-put-tag " " t))))

(defun browsel-tab-manager-toggle-all-marks ()
  "Toggle marks on every tab: marked rows unmark, unmarked rows mark."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (let ((char (char-after (line-beginning-position))))
        (tabulated-list-put-tag (if (eq char ?D) " " "D") t)))))

(defun browsel-tab-manager--marked-actions ()
  "Return an alist of (row-id . tag) for every currently-marked row.
TAG is `delete' for `D'-tagged rows and `bookmark' for `B'-tagged
rows.  Rows in the order they appear in the buffer, so `x'
executes top-to-bottom."
  (let (marked)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let ((c (char-after (line-beginning-position))))
          (cond ((eq c ?D) (push (cons (tabulated-list-get-id) 'delete)   marked))
                ((eq c ?B) (push (cons (tabulated-list-get-id) 'bookmark) marked))))
        (forward-line 1)))
    (nreverse marked)))

(defun browsel-tab-manager-execute ()
  "Execute every mark: bookmark `B'-marked tabs, close `D'-marked tabs.
Bookmarks fire first so a bookmark-then-close pair still records
the URL before it becomes unreachable.  Bookmark names are the
tab's title; collisions get a `<N>' suffix so no existing bookmark
is silently overwritten.  Honours `browsel-tab-manager-confirm-close'
for the count prompt when any `D' marks are present."
  (interactive)
  (let* ((marked    (browsel-tab-manager--marked-actions))
         (deletes   (seq-filter (lambda (m) (eq (cdr m) 'delete))   marked))
         (bookmarks (seq-filter (lambda (m) (eq (cdr m) 'bookmark)) marked))
         (nd (length deletes))
         (nb (length bookmarks)))
    (cond
     ((zerop (+ nd nb))
      (message "No tabs marked"))
     ((and (> nd 0)
           browsel-tab-manager-confirm-close
           (not (yes-or-no-p
                 (if (> nb 0)
                     (format "Execute: bookmark %d, close %d? " nb nd)
                   (format "Close %d marked tab%s? "
                           nd (if (= nd 1) "" "s"))))))
      (message "browsel-tab-manager: cancelled"))
     (t
      (let ((booked 0) (closed 0))
        (dolist (m bookmarks)
          (let ((tab (cdr (assoc (car m) browsel-tab-manager--tabs))))
            (when tab
              (condition-case err
                  (let* ((raw  (or (plist-get tab :title) "(untitled)"))
                         (name (browsel-tab-manager--unique-bookmark-name raw)))
                    (funcall browsel-tab-manager-bookmark-function name tab)
                    (setq booked (1+ booked)))
                (error
                 (message "Bookmark failed for %s: %s"
                          (plist-get tab :title)
                          (error-message-string err)))))))
        (dolist (m deletes)
          (let ((tab (cdr (assoc (car m) browsel-tab-manager--tabs))))
            (when tab
              (condition-case err
                  (progn (browsel-close-tab tab)
                         (setq closed (1+ closed)))
                (error
                 (message "Could not close %s: %s"
                          (plist-get tab :title)
                          (error-message-string err)))))))
        (message "browsel-tab-manager: bookmarked %d/%d, closed %d/%d"
                 booked nb closed nd)
        (browsel-tab-manager--refresh))))))

(defun browsel-tab-manager-delete-immediate ()
  "Close the tab on the current line immediately, no mark, no confirmation."
  (interactive)
  (let ((tab (browsel-tab-manager--tab-at-point)))
    (cond
     ((null tab)
      (message "No tab on this line"))
     (t
      (condition-case err
          (progn
            (browsel-close-tab tab)
            (browsel-tab-manager--refresh)
            (message "Closed %s" (plist-get tab :title)))
        (error
         (message "Could not close %s: %s"
                  (plist-get tab :title)
                  (error-message-string err))))))))

(defun browsel-tab-manager-visit-tab ()
  "Focus the tab on the current line, raising its browser window.
Stays in the manager buffer.  Compare `browsel-tab-manager-preview-tab',
which does not raise the browser window."
  (interactive)
  (let ((tab (browsel-tab-manager--tab-at-point)))
    (if (null tab)
        (message "No tab on this line")
      (condition-case err
          (browsel-focus-tab tab t)
        (error
         (message "Could not focus %s: %s"
                  (plist-get tab :title)
                  (error-message-string err)))))))

(defun browsel-tab-manager-preview-tab ()
  "Show the tab on the current line in its browser without raising the window.
Stays in the manager buffer with Emacs still focused."
  (interactive)
  (let ((tab (browsel-tab-manager--tab-at-point)))
    (if (null tab)
        (message "No tab on this line")
      (condition-case err
          (browsel-focus-tab tab nil)
        (error
         (message "Could not preview %s: %s"
                  (plist-get tab :title)
                  (error-message-string err)))))))

(defun browsel-tab-manager-cycle-sort ()
  "Cycle the sort key through mru → title → domain → window → mru."
  (interactive)
  (setq browsel-tab-manager--buffer-sort
        (browsel-tab-manager--next-sort
         (or browsel-tab-manager--buffer-sort browsel-tab-manager-sort)))
  (browsel-tab-manager--refresh))

(defun browsel-tab-manager-toggle-url ()
  "Toggle the location column between hostname (default) and full URL.
When URL view is on the column becomes `URL' with a wider width
\(`browsel-tab-manager-url-column-width') and each row shows the
tab's full URL, truncated with `…' if longer.  The header line
displays `URL view' while active."
  (interactive)
  (setq browsel-tab-manager--show-url (not browsel-tab-manager--show-url))
  (browsel-tab-manager--refresh))

(defun browsel-tab-manager-copy-url ()
  "Copy the URL of the tab on the current line to the kill ring."
  (interactive)
  (let* ((tab (browsel-tab-manager--tab-at-point))
         (url (and tab (plist-get tab :url))))
    (if (and (stringp url) (not (string-empty-p url)))
        (progn (kill-new url)
               (message "Copied: %s" url))
      (message "No URL on this line"))))

(defun browsel-tab-manager-set-filter (regex)
  "Filter the buffer to rows whose title, URL, or domain match REGEX.
Empty input clears the filter.  The current filter is shown in the
mode line as `/REGEX/'."
  (interactive
   (list (read-string
          (format "Filter regex (%s): "
                  (if browsel-tab-manager--filter
                      (format "current: /%s/, empty clears"
                              browsel-tab-manager--filter)
                    "empty clears"))
          nil nil "")))
  (setq browsel-tab-manager--filter
        (and (stringp regex) (not (string-empty-p regex)) regex))
  (browsel-tab-manager--refresh))

(defun browsel-tab-manager-mark-duplicates ()
  "Mark duplicate tabs (older copies) for deletion.
Uses the same rule as `browsel-tab-manager-close-duplicates': URLs
match after `#fragment' strip, pinned tabs are skipped, and the
most-recently-accessed tab in each group is kept.  Duplicates are
computed within each browser separately."
  (interactive)
  (let* ((tabs       (mapcar #'cdr browsel-tab-manager--tabs))
         (victims    (browsel-tab-manager--duplicate-victims tabs))
         (victim-ids (mapcar #'browsel-tab-manager--row-id victims)))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when (member (tabulated-list-get-id) victim-ids)
          (tabulated-list-put-tag "D" nil))
        (forward-line 1)))
    (message "Marked %d duplicate tab%s"
             (length victim-ids)
             (if (= (length victim-ids) 1) "" "s"))))

;; ── Bookmark support ──────────────────────────────────────────────────────
;;
;; `b' marks the current row with a `B' tag; `x' bookmarks every
;; B-marked tab using the tab's title as the bookmark name.  `B'
;; bookmarks the current tab immediately, prompting for the name
;; (default = tab title).  The backend is
;; `browsel-tab-manager-bookmark-function' — plug in bookmark+ or
;; another store by overriding the defcustom.

(defun browsel-tab-manager-bookmark-jump (bookmark)
  "Handler for URL bookmarks created by `browsel-tab-manager-bookmark-default'.
Reads the URL from BOOKMARK's `filename' entry and dispatches
via `browse-url'.  Guaranteed to be available whenever
browsel-tab-manager itself is loaded, so it does not depend on
`browse-url-bookmark-jump' (not autoloaded in every Emacs) or
`bmkp-jump-url-browse' (only present with bookmark+)."
  (let ((url (bookmark-prop-get bookmark 'filename)))
    (unless (and (stringp url) (not (string-empty-p url)))
      (error "browsel-tab-manager-bookmark-jump: no URL in bookmark"))
    (browse-url url)))

(defun browsel-tab-manager-bookmark-default (name tab)
  "Default bookmark backend using `browsel-tab-manager-bookmark-jump'.
Stores a `bookmark-store' record named NAME whose `filename' is
TAB's URL and whose `handler' is our own jumper.  Users with
bookmark+ can override `browsel-tab-manager-bookmark-function' to
plug in `bmkp-jump-url-browse' for a nicer `*Bookmark List*'
display — but the default works everywhere, no autoload required."
  (let ((url (or (plist-get tab :url) "")))
    (bookmark-store name
                    `((filename . ,url)
                      (handler  . browsel-tab-manager-bookmark-jump))
                    nil)))

(defun browsel-tab-manager--unique-bookmark-name (name)
  "Return NAME, or NAME<N> for the smallest N that avoids a collision.
Used by the batch (`x') bookmark path so a name-collision does not
overwrite a prior bookmark silently.  The immediate path (`B') asks
the user directly and does not go through this helper."
  (if (not (bookmark-get-bookmark name t))
      name
    (cl-loop for n from 2
             for candidate = (format "%s<%d>" name n)
             unless (bookmark-get-bookmark candidate t)
             return candidate)))

(defun browsel-tab-manager-mark-bookmark (&optional _arg)
  "Mark the tab on the current line for bookmarking and advance one line.
Executed by `x' using the tab's title as the bookmark name; use
`B' to bookmark immediately with a prompt.  A prior `D' mark on
this row is overwritten (dired: one mark per row)."
  (interactive "p")
  (tabulated-list-put-tag "B" t))

(defun browsel-tab-manager-bookmark-immediate ()
  "Bookmark the tab on the current line immediately, prompting for the name.
Default at the prompt is the tab's title.  If a bookmark under
that name already exists the user is asked whether to overwrite;
answering `n' aborts the operation."
  (interactive)
  (let ((tab (browsel-tab-manager--tab-at-point)))
    (cond
     ((null tab)
      (message "No tab on this line"))
     (t
      (let* ((default-name (or (plist-get tab :title) "(untitled)"))
             (name (read-string
                    (format "Bookmark name (default %s): " default-name)
                    nil nil default-name)))
        (cond
         ((or (null name) (string-empty-p name))
          (message "Bookmark aborted (empty name)"))
         ((and (bookmark-get-bookmark name t)
               (not (yes-or-no-p
                     (format "Bookmark %S exists — overwrite? " name))))
          (message "Bookmark aborted"))
         (t
          (condition-case err
              (progn
                (funcall browsel-tab-manager-bookmark-function name tab)
                (message "Bookmarked %s" name))
            (error
             (message "Bookmark failed: %s" (error-message-string err))))))))))
  nil)

;; ── Keymap and mode ────────────────────────────────────────────────────────

(defvar browsel-tab-manager-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET")        #'browsel-tab-manager-visit-tab)
    (define-key map (kbd "<return>")   #'browsel-tab-manager-visit-tab)
    (define-key map (kbd "M-RET")      #'browsel-tab-manager-preview-tab)
    (define-key map (kbd "M-<return>") #'browsel-tab-manager-preview-tab)
    (define-key map (kbd "d")          #'browsel-tab-manager-mark-delete)
    (define-key map (kbd "b")          #'browsel-tab-manager-mark-bookmark)
    (define-key map (kbd "B")          #'browsel-tab-manager-bookmark-immediate)
    (define-key map (kbd "u")          #'browsel-tab-manager-unmark)
    (define-key map (kbd "U")          #'browsel-tab-manager-unmark-all)
    (define-key map (kbd "t")          #'browsel-tab-manager-toggle-all-marks)
    (define-key map (kbd "x")          #'browsel-tab-manager-execute)
    (define-key map (kbd "D")          #'browsel-tab-manager-delete-immediate)
    (define-key map (kbd "s")          #'browsel-tab-manager-cycle-sort)
    (define-key map (kbd "w")          #'browsel-tab-manager-copy-url)
    (define-key map (kbd "/")          #'browsel-tab-manager-set-filter)
    (define-key map (kbd "v")          #'browsel-tab-manager-toggle-url)
    (define-key map (kbd "= d")        #'browsel-tab-manager-mark-duplicates)
    map)
  "Keymap for `browsel-tab-manager-mode'.
`g' (refresh), `n' / `p' (line navigation), and `q' (quit-window)
are inherited from `tabulated-list-mode' / `special-mode'.")

(define-derived-mode browsel-tab-manager-mode tabulated-list-mode "Tabs"
  "Major mode for browsing and managing open browser tabs across
every connected browser.  See the keymap below.

Columns:
  Client     the browser that owns the tab (chrome, firefox,
             or a user-set label like `chrome-work').  Shown only
             when two or more browsers are represented in the
             current view; suppressed for single-browser views.
  Flags      three characters describing tab state; a lowercase
             letter means the flag is set, a space means it is
             not:
               a   active — the focused tab in its window
               s   sound — audible (playing audio)
               i   incognito
  Domain     the URL's host, truncated to
             `browsel-tab-manager-domain-column-width'.  When
             URL view is toggled on (`v'), the column becomes
             `URL' and shows the full URL truncated to
             `browsel-tab-manager-url-column-width'.
  Title      the tab's title as reported by the browser.

The header line above the table shows the current sort key, the
active regex filter (when any), and `URL view' (when the URL
toggle is on).

The one-character prefix left of the Client column is the
mark tag: `D' means the tab is marked for closing by `x', and
`B' means the tab is marked for bookmarking by `x' (using the
tab's title as the bookmark name).  One mark per row — pressing
`d' on a `B'-marked row replaces the tag, dired-style.

\\<browsel-tab-manager-mode-map>
Marking (dired-style — one mark per row):
  \\[browsel-tab-manager-mark-delete]     mark the current tab for deletion   (`D' tag)
  \\[browsel-tab-manager-mark-bookmark]     mark the current tab for bookmarking (`B' tag)
  \\[browsel-tab-manager-unmark]     clear the mark on the current tab
  \\[browsel-tab-manager-unmark-all]     clear every mark
  \\[browsel-tab-manager-toggle-all-marks]     toggle every mark (delete-marks only)
  \\[browsel-tab-manager-mark-duplicates]   mark duplicate tabs for deletion

Acting on tabs:
  \\[browsel-tab-manager-execute]     execute marks: bookmark `B's, close `D's (single confirm for closes)
  \\[browsel-tab-manager-delete-immediate]     close the current tab immediately, no confirmation
  \\[browsel-tab-manager-bookmark-immediate]     bookmark the current tab immediately, prompting for the name
  \\[browsel-tab-manager-visit-tab]   focus the current tab and raise its browser window; stay in manager
  \\[browsel-tab-manager-preview-tab]   preview the current tab in its browser without raising the window

Buffer state:
  \\[revert-buffer]     refresh (re-fetch every browser's tabs)
  \\[browsel-tab-manager-cycle-sort]     cycle sort key (mru → title → domain → window)
  \\[browsel-tab-manager-set-filter]     regex filter on title / URL / domain (empty clears)
  \\[browsel-tab-manager-toggle-url]     toggle the location column between hostname and full URL
  \\[browsel-tab-manager-copy-url]     copy the current tab's URL to the kill ring
  q     quit-window

Row id is (INSTANCE . TAB-ID); the same tab keeps its point
position across refreshes even when the surrounding list has
changed."
  (setq tabulated-list-padding 2)
  (setq revert-buffer-function #'browsel-tab-manager--refresh))

;;;###autoload
(defun browsel-tab-manager ()
  "Open the *browsel-tab-manager* buffer listing every browser's tabs.
See `browsel-tab-manager-mode' for the keymap and behaviour.
Unlike `browsel-tab-jump' (the completing-read entry point), this
command opens a persistent buffer you can leave open and refresh
with `g'.  `browsel-default-client' is ignored — every connected
browser is represented; use the buffer-local filter (`/') or the
consult-style narrow-by-typing to focus on a subset."
  (interactive)
  (unless (browsel-connected-clients)
    (user-error "Browsel: no browser connected"))
  (let ((buf (get-buffer-create "*browsel-tab-manager*")))
    (with-current-buffer buf
      (browsel-tab-manager-mode)
      (browsel-tab-manager--refresh))
    (pop-to-buffer buf)))

(provide 'browsel-tab-manager)


;; Local Variables:
;; package-lint-main-file: "browsel.el"
;; End:

;;; browsel-tab-manager.el ends here
