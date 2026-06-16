;;; browsel-pkg.el --- Package descriptor for browsel  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Daniel M. German <dmg@turingmachine.org>

;; This file declares browsel as a multi-file Emacs package.
;; The optional backends (-www, -chatgpt, -youtube, -babel) are part
;; of the same distribution but are loaded only when the user calls
;; (require ...) on each.

(define-package "browsel" "0.8"
  "Bidirectional bridge between Emacs and a Chrome/Firefox extension"
  '((emacs "27.1") (websocket "1.13"))
  :url       "https://github.com/dmgerman/browsel"
  :keywords  '("comm" "tools" "browser" "org")
  :maintainer '("Daniel M. German" . "dmg@turingmachine.org")
  :authors   '(("Daniel M. German" . "dmg@turingmachine.org")))

;;; browsel-pkg.el ends here
