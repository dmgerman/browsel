;;; chrome-server-www.el --- Web page archiving backend for chrome-server

;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; Author: Daniel M. German <dmg@turingmachine.org>
;; Maintainer: Daniel M. German <dmg@turingmachine.org>
;; Keywords: browser, http, org, archive
;; Homepage: https://github.com/dmgerman

;;; Commentary:

;; Web page archiving backend for chrome-server.
;; Provides the POST /save-page endpoint which saves the main content of any
;; web page to ~/sync/www-archive/<basename>/ as both an HTML file and an org
;; file (converted via pandoc).  Embedded images are extracted to the same
;; directory by pandoc's --extract-media flag.
;;
;; Payload:
;;   { "version": 1, "payload": { "url": "...", "title": "...", "html": "..." } }

;;; Code:

(require 'chrome-server)

;; ── Configuration ────────────────────────────────────────────────────────────

(defvar chrome-server-www-archive-dir "~/sync/www-archive"
  "Directory where saved web pages are stored.")

;; ── Endpoint ─────────────────────────────────────────────────────────────────

(defservlet save-page application/json (path query request)
  "Handle POST /save-page — save main page content to ~/sync/www-archive/."
  (condition-case err
      (let* ((data    (chrome-server--parse-request request))
             (payload (plist-get data :payload)))
        (unless payload
          (error "chrome-server-www: missing 'payload' key in request"))
        (let ((file (chrome-server-www--save payload)))
          (chrome-server--respond 200 "ok" (format "Saved to %s" file))))
    (error
     (chrome-server--respond 500 "error" (error-message-string err)))))

;; ── Page saving ───────────────────────────────────────────────────────────────

(defun chrome-server-www--save (payload)
  "Save web page PAYLOAD to a per-item directory under `chrome-server-www-archive-dir'.
Each save creates a new directory named <timestamp>-<title>/ containing
<basename>.org, <basename>.html, and any extracted images.
Returns the path of the org file written."
  (let* ((url      (plist-get payload :url))
         (title    (or (plist-get payload :title) "web-page"))
         (html     (plist-get payload :html))
         (root     (expand-file-name chrome-server-www-archive-dir))
         (basename (format "%s-%s"
                           (format-time-string "%Y%m%d-%H%M%S")
                           (chrome-server-www--sanitize-title title)))
         (page-dir  (expand-file-name basename root))
         (file      (expand-file-name (concat basename ".org")  page-dir))
         (html-file (expand-file-name (concat basename ".html") page-dir)))
    (unless html
      (error "chrome-server-www: payload contains no 'html'"))
    (condition-case err
        (make-directory page-dir t)
      (error
       (error "chrome-server-www: could not create directory %s: %s"
              page-dir (error-message-string err))))
    (condition-case err
        (with-temp-file html-file
          (insert html))
      (error
       (message "chrome-server-www: could not save HTML file %s: %s"
                html-file (error-message-string err))))
    (condition-case err
        (with-temp-file file
          (insert (format "#+title: %s\n" title))
          (insert (format "#+source_url: %s\n" url))
          (insert (format "#+created: %s\n\n" (format-time-string "%Y-%m-%d %H:%M:%S")))
          (insert (format "[[%s][%s]]\n\n" url title))
          (insert (condition-case err
                      (chrome-server-www--html-to-org html page-dir)
                    (error
                     (message "chrome-server-www: HTML conversion failed, inserting plain text: %s"
                              (error-message-string err))
                     html))))
      (error
       (error "chrome-server-www: could not write org file %s: %s"
              file (error-message-string err))))
    file))

(defun chrome-server-www--html-to-org (html media-dir)
  "Convert HTML string to org format via pandoc.
Images are extracted to MEDIA-DIR via pandoc's --extract-media flag.
Signals an error if pandoc is not found or exits non-zero."
  (unless (executable-find chrome-server-pandoc-executable)
    (error "chrome-server-www: pandoc not found (set chrome-server-pandoc-executable)"))
  (with-temp-buffer
    (let ((exit-code (call-process-region html nil
                                          chrome-server-pandoc-executable
                                          nil t nil
                                          "-f" "html" "-t" "org"
                                          "--wrap=none"
                                          (format "--extract-media=%s" media-dir))))
      (unless (zerop exit-code)
        (error "chrome-server-www: pandoc failed (exit %d): %s"
               exit-code (buffer-string)))
      (goto-char (point-min))
      (while (re-search-forward "^\\*+ +<<[^>]+>>\\s-*$" nil t)
        (delete-region (line-beginning-position)
                       (min (1+ (line-end-position)) (point-max))))
      (goto-char (point-min))
      (while (re-search-forward "<<[^>]+>>" nil t)
        (replace-match ""))
      (buffer-string))))

(defun chrome-server-www--sanitize-title (title)
  "Sanitize TITLE for use as a filename component (max 40 chars)."
  (let* ((s (downcase title))
         (s (replace-regexp-in-string "[^a-z0-9]+" "-" s))
         (s (replace-regexp-in-string "^-+\\|-+$" "" s)))
    (truncate-string-to-width s 40)))

(provide 'chrome-server-www)

;;; chrome-server-www.el ends here
