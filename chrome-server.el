;;; chrome-server.el --- HTTP bridge between Chrome extensions and Emacs

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; Author: Daniel M. German <dmg@turingmachine.org>
;; Maintainer: Daniel M. German <dmg@turingmachine.org>
;; Keywords: browser, http, org
;; Homepage: https://github.com/dmgerman

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;;; Commentary:

;; Provides a local HTTP server that receives JSON requests from a Chrome
;; extension and dispatches them to registered action handlers.
;;
;; Generic endpoints:
;;
;;   POST /org-capture       -- org-capture (template key configurable)
;;   POST /org-roam-capture  -- standard org-roam-capture (template chosen interactively)
;;   POST /eww               -- open URL in eww
;;
;; Both capture endpoints accept:
;;   { "version": 1, "payload": { "url": "...", "title": "...", "text": "..." } }
;;
;; /eww accepts:
;;   { "version": 1, "payload": { "url": "..." } }
;;
;; Backend-specific endpoints are provided by separate files, e.g.:
;;   chrome-server-chatgpt.el  -- POST /chatgpt
;;   chrome-server-www.el      -- POST /save-page
;;
;; Usage:
;;   (require 'chrome-server)
;;   (chrome-server-start)   ; start the server
;;   (chrome-server-stop)    ; stop the server

;;; Code:

(require 'simple-httpd)
(require 'json)

;; ── Configuration ────────────────────────────────────────────────────────────

(defvar chrome-server-port 9129
  "Port the Chrome server HTTP server listens on.")

(defvar chrome-server-org-capture-key nil
  "Org-capture template key used by the /org-capture endpoint.
nil means the user selects the template interactively.")

;; ── Server lifecycle ─────────────────────────────────────────────────────────

(defun chrome-server-start ()
  "Start the Chrome server HTTP server."
  (interactive)
  (setq httpd-port chrome-server-port
        httpd-host "127.0.0.1")
  (httpd-start)
  (message "Chrome server started on port %d" chrome-server-port))

(defun chrome-server-stop ()
  "Stop the Chrome server HTTP server."
  (interactive)
  (httpd-stop)
  (message "Chrome server stopped"))

;; ── HTTP helpers ─────────────────────────────────────────────────────────────

(defun chrome-server--respond (status-code status message &optional data)
  "Insert a JSON response body and send headers with STATUS-CODE.
STATUS is the string \"ok\" or \"error\", MESSAGE is human-readable,
DATA is optional extra data."
  (insert (json-encode `(:status ,status :message ,message :data ,(or data :null))))
  (httpd-send-header t "application/json" status-code
                     :Access-Control-Allow-Origin "*"
                     :Access-Control-Allow-Methods "POST, OPTIONS"
                     :Access-Control-Allow-Headers "Content-Type"))

(defun chrome-server--parse-request (request)
  "Parse the JSON body from REQUEST and return a plist.
Signals an error if the body is missing or not valid JSON."
  (let ((raw (cadr (assoc "Content" request))))
    (unless raw
      (error "chrome-server: request body is empty"))
    (let ((body (decode-coding-string raw 'utf-8)))
      (condition-case err
          (json-parse-string body :object-type 'plist :array-type 'list)
        (json-parse-error
         (error "chrome-server: invalid JSON: %s" (error-message-string err)))))))

;; ── Endpoints ────────────────────────────────────────────────────────────────

(defservlet org-capture application/json (path query request)
  "Handle POST /org-capture — org-capture with configurable template key."
  (condition-case err
      (let* ((data    (chrome-server--parse-request request))
             (payload (plist-get data :payload)))
        (unless payload
          (error "chrome-server: missing 'payload' key in request"))
        (chrome-server--respond 200 "ok" "Org-capture opened")
        (run-at-time 0 nil #'chrome-server--org-capture payload))
    (error
     (chrome-server--respond 500 "error" (error-message-string err)))))

(defservlet org-roam-capture application/json (path query request)
  "Handle POST /org-roam-capture — org-roam-capture with interactive template selection."
  (condition-case err
      (let* ((data    (chrome-server--parse-request request))
             (payload (plist-get data :payload)))
        (unless payload
          (error "chrome-server: missing 'payload' key in request"))
        (chrome-server--respond 200 "ok" "Org-roam-capture opened")
        (run-at-time 0 nil #'chrome-server--org-roam-capture payload))
    (error
     (chrome-server--respond 500 "error" (error-message-string err)))))

;; ── Action handlers ───────────────────────────────────────────────────────────

(defun chrome-server--maybe-raise (payload)
  "Raise and focus Emacs frame if PAYLOAD contains :raise t."
  (when (eq (plist-get payload :raise) t)
    (select-frame-set-input-focus (selected-frame))))

(defun chrome-server--capture-initial (payload)
  "Build the org-capture-initial string from PAYLOAD's url, title, and text."
  (let* ((url   (plist-get payload :url))
         (title (or (plist-get payload :title) "Web capture"))
         (text  (or (plist-get payload :text) "")))
    (concat (format "[[%s][%s]]" url title)
            (unless (string-empty-p text) (concat "\n\n" text)))))

;; ── Payload cache ─────────────────────────────────────────────────────────────

(defvar chrome-server--current-url nil
  "URL from the most recent chrome-server payload.
Bound dynamically during capture so templates can access it via
`%(chrome-server-get-url)'.")

(defvar chrome-server--current-title nil
  "Title from the most recent chrome-server payload.
Bound dynamically during capture so templates can access it via
`%(chrome-server-get-title)'.")

(defvar chrome-server--current-text nil
  "Selected text from the most recent chrome-server payload.
Bound dynamically during capture so templates can access it via
`%(chrome-server-get-selection)'.")

(defun chrome-server-get-url ()
  "Return the URL from the current chrome-server payload and clear it.
Returns an empty string if not set or already consumed.
Use as `%(chrome-server-get-url)' in an org-capture template."
  (prog1 (or chrome-server--current-url "")
    (setq chrome-server--current-url nil)))

(defun chrome-server-get-title ()
  "Return the title from the current chrome-server payload and clear it.
Returns an empty string if not set or already consumed.
Use as `%(chrome-server-get-title)' in an org-capture template."
  (prog1 (or chrome-server--current-title "")
    (setq chrome-server--current-title nil)))

(defun chrome-server-get-selection ()
  "Return the selected text from the current chrome-server payload and clear it.
Returns an empty string if not set or already consumed.
Use as `%(chrome-server-get-selection)' in an org-capture template."
  (prog1 (or chrome-server--current-text "")
    (setq chrome-server--current-text nil)))

(defun chrome-server--org-capture (payload)
  "Open org-capture pre-filled from PAYLOAD.
Uses `chrome-server-org-capture-key' if set, otherwise prompts interactively."
  (condition-case err
      (let ((org-capture-initial (chrome-server--capture-initial payload)))
        (setq chrome-server--current-url   (plist-get payload :url)
              chrome-server--current-title (or (plist-get payload :title) "")
              chrome-server--current-text  (or (plist-get payload :text) ""))
        (chrome-server--maybe-raise payload)
        (org-capture nil chrome-server-org-capture-key))
    (error
     (message "chrome-server: org-capture failed: %s" (error-message-string err)))))

(defun chrome-server--org-roam-capture (payload)
  "Open org-roam-capture, storing PAYLOAD URL as the initial link."
  (condition-case err
      (let ((org-capture-initial (chrome-server--capture-initial payload)))
        (setq chrome-server--current-url   (plist-get payload :url)
              chrome-server--current-title (or (plist-get payload :title) "")
              chrome-server--current-text  (or (plist-get payload :text) ""))
        (chrome-server--maybe-raise payload)
        (org-roam-capture-
         :node (org-roam-node-create)))
    (error
     (message "chrome-server: org-roam-capture failed: %s" (error-message-string err)))))

;; ── eww ───────────────────────────────────────────────────────────────────────

(defservlet eww application/json (path query request)
  "Handle POST /eww — open the payload URL in eww."
  (condition-case err
      (let* ((data    (chrome-server--parse-request request))
             (payload (plist-get data :payload)))
        (unless payload
          (error "chrome-server: missing 'payload' key in request"))
        (chrome-server--respond 200 "ok" "Opening in eww")
        (run-at-time 0 nil #'chrome-server--eww payload))
    (error
     (chrome-server--respond 500 "error" (error-message-string err)))))

(defun chrome-server--eww (payload)
  "Open the URL from PAYLOAD in eww."
  (condition-case err
      (let ((url (plist-get payload :url)))
        (unless url
          (error "chrome-server: missing url in payload"))
        (chrome-server--maybe-raise payload)
        (eww url))
    (error
     (message "chrome-server: eww failed: %s" (error-message-string err)))))

(provide 'chrome-server)

;;; chrome-server.el ends here
