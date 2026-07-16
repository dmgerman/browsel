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
;; the browsel WebSocket bridge.
;;
;; Commands:
;;
;;   `browsel-tab-manager'
;;     List every open tab and focus the pick.  Each row renders
;;     `[flags] DOMAIN  TITLE' with separate faces so the three
;;     columns are visually distinct.  In-prompt action keys:
;;       ?       help (legend + bindings)
;;       RET     focus the tab + window, exit
;;       M-RET   preview: show the tab in its window, stay in the prompt
;;       M-k     close the highlighted tab (see -confirm-close)
;;       C-c c   copy URL to the kill ring, stay in the prompt
;;       C-t     cycle sort: mru -> title -> domain -> window
;;     Both M-k (no-confirm path) and C-t preserve the typed
;;     filter on re-entry.
;;
;;   `browsel-tab-manager-close-duplicates'
;;     Close duplicate tabs in one sweep.  URLs match after the
;;     `#fragment' is stripped; pinned tabs are skipped; the most-
;;     recently-accessed tab in each duplicate group is kept.
;;     Confirms with a count before closing anything.
;;
;; Which connected client (chrome / firefox) the tab manager
;; addresses is the same default the rest of browsel uses — set
;; `browsel-default-client' in `browsel.el' once and every command
;; honours it.  With several clients connected and no default set,
;; the resolver prompts.
;;
;; User-tunable variables: `browsel-tab-manager-sort',
;; `browsel-tab-manager-confirm-close',
;; `browsel-tab-manager-domain-column-width'.  Faces:
;; `browsel-tab-manager-flags-face', `-domain-face', `-title-face'.

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

(defcustom browsel-tab-manager-sort 'mru
  "Default sort order for `browsel-tab-manager' candidates.
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
When non-nil, `M-k' inside `browsel-tab-manager' prompts
with `yes-or-no-p' showing the tab's title before issuing CLOSE_TAB.
When nil, closures fire immediately on the first keystroke.
Has no effect on `browsel-tab-manager-close-duplicates', which has
its own count-based confirmation."
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
;; While `browsel-tab-manager' is reading a candidate the
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
Bound by `browsel-tab-manager' for the duration of the
`completing-read' call so the in-prompt action commands can look up
the tab plist that backs the highlighted display string.")

(defvar browsel-tab-manager--current-sort nil
  "Dynamic binding: sort key the active prompt is showing.
Used by `browsel-tab-manager-jump-cycle-sort' to compute the next
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

(defun browsel-tab-manager-jump-help ()
  "Show in-prompt help for `browsel-tab-manager'."
  (interactive)
  (with-help-window "*browsel-tab-manager help*"
    (princ "browsel-tab-manager — jump-to-tab in-prompt actions\n")
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

(defun browsel-tab-manager-jump-show-tab ()
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

(defun browsel-tab-manager-jump-copy-url ()
  "Copy the highlighted candidate's tab URL to the kill ring."
  (interactive)
  (let* ((tab (browsel-tab-manager--current-tab))
         (url (and tab (plist-get tab :url))))
    (if (and (stringp url) (not (string-empty-p url)))
        (progn (kill-new url)
               (message "Copied: %s" url))
      (message "No candidate selected"))))

(defun browsel-tab-manager-jump-cycle-sort ()
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

(defun browsel-tab-manager-jump-close-tab ()
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
  '(("?"     . browsel-tab-manager-jump-help)
    ("C-c c" . browsel-tab-manager-jump-copy-url)
    ("M-k"   . browsel-tab-manager-jump-close-tab)
    ("M-RET" . browsel-tab-manager-jump-show-tab)
    ("C-t"   . browsel-tab-manager-jump-cycle-sort))
  "Single source of truth for jump-to-tab in-prompt keys.
Installed onto whatever local map the active completion frontend
\(vertico, icomplete, default) provides; see
`browsel-tab-manager--install-keys'.")

(defun browsel-tab-manager--install-keys ()
  "Add the in-prompt action keys to the current minibuffer's local map.
Earlier code composed `browsel-tab-manager-jump-map' on top of the
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
(defun browsel-tab-manager (&optional clients)
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
  \\[browsel-tab-manager-jump-copy-url]   copy the highlighted candidate's URL to the kill ring
  \\[browsel-tab-manager-jump-close-tab]     close the highlighted candidate's tab and stay in the prompt
  \\[browsel-tab-manager-jump-show-tab]   show the highlighted tab in its browser without raising the window
  \\[browsel-tab-manager-jump-cycle-sort]     cycle the sort order"
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

(provide 'browsel-tab-manager)


;; Local Variables:
;; package-lint-main-file: "browsel.el"
;; End:

;;; browsel-tab-manager.el ends here
