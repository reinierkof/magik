;;; magik-completion-prefixes.el --- This file contains the prefix functions to determine whether the user is at a certain prefix or not.  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Author:  <reinier.koffijberg@keronic.com>
;; Keywords: lisp

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:

;; `magik-session' `require's `magik-mode', so this file cannot `require' it
;; at load time without creating a load cycle when `magik-mode.el' pulls in
;; `magik-completion' — see `magik-completion.el's `magik-completion--enable',
;; which `require's it lazily at mode activation time instead.
(defvar magik-session-prompt)

(defvar magik-completion-cur-prefix nil)
(defvar magik-completion-prefix-at-methods nil)
(defvar magik-completion-prefix-at-conditions nil)
(defvar magik-completion-prefix-at-dynamics nil)
(defvar magik-completion-prefix-at-globals nil)
(defvar magik-completion-prefix-at-objects nil)
(defvar magik-completion-prefix-at-slot nil)

(defun magik-completion--determine-cur-prefix()
  "The prefix from recent characters."
  (let ((start (line-beginning-position))
	(end (point))
	(regex "[^a-zA-Z0-9:_!<^]+")
	result)
    (save-excursion
      (if (re-search-backward regex start t)
	  (setq result (buffer-substring-no-properties (+ 1 (point)) end))
	(setq result (buffer-substring-no-properties start end))))
    (setq magik-completion-cur-prefix (downcase result))
    magik-completion-cur-prefix))

(defun magik-completion--in-comment ()
  "Check if the current line start is with #, ignore whitespaces."
  (save-excursion
    (beginning-of-line)
    (looking-at-p "^[ \t]*#")))

(defun magik-completion--in-string ()
  "Check if the current point is inside double quotes (\") or single quotes (')."
  (let ((syntax (syntax-ppss)))
    (nth 3 syntax)))

(defun magik-completion--at-method-prefix ()
  "Detect if point is at . method point."
  (save-excursion
    (re-search-backward "\\(_self\\|_clone\\|\\S-\\)\\.\\(\\sw+\\)\\=" (line-beginning-position) t)))

(defun magik-completion--at-raise-condition-prefix ()
  "Detect if the point is at condition.raise(: ."
  (save-excursion
    (if (re-search-backward "condition\\.raise(\\s-*:\\(\\sw+\\)\\=" (line-beginning-position) t)
	t
      nil)))

(defun magik-completion--at-slot-prefix ()
  "Detect if the point is at .variable ."
  (save-excursion
    (if (re-search-backward "\\(?:^\\|[^[:word:].]\\)\\.\\w*\\="
			    (line-beginning-position) t)
	t
      nil)))

(defun magik-completion--at-dynamic-prefix ()
  "Detect if the point is at a !..! dynamic prefix."
  (save-excursion
    (if (and (re-search-backward "\\Sw\\(!\\sw*\\)\\=" (line-beginning-position) t)
	     (not (eq (following-char) ?.))
	     (not (equal ":" (buffer-substring-no-properties (match-beginning 1) (1+ (match-beginning 1))))))
	t
      nil)))

(defun magik-completion--at-global-prefix ()
  "Detect if the point is at a possible global."
  (save-excursion
    (if (re-search-backward "\\b\\(\\sw+\\)\\_>" (line-beginning-position) t)
	(let ((start (match-beginning 0)))
	  (if (and start
		   (> start (point-min))
		   (not (eq (char-before start) ?.)))
	      t
	    nil))
      nil)))

(defun magik-completion--at-object-prefix ()
  "Detect if the point is at a possible object.
Allows for single words or two words connected with a ':'."
  (save-excursion
    (if (or
	 (re-search-backward "\\b\\(\\sw+\\):\\(\\sw+\\)\\_>" (line-beginning-position) t)
	 (re-search-backward "\\b\\(\\sw+\\)\\_>" (line-beginning-position) t))
	(let ((start (match-beginning 0)))
	  (if (and start
		   (> start (point-min))
		   (not (eq (char-before start) ?.)))
	      t
	    nil))
      nil)))

(defun magik-completion--session-within-typeable-area()
  "Detect if we are in a command."
  (save-excursion
    (let ((cursor-loc (point)))
      (goto-char (point-max))
      (let ((magik-prefix-pos (save-excursion (when (re-search-backward magik-session-prompt nil t)
						(match-end 0)))))
	(if (and (number-or-marker-p magik-prefix-pos)
		 (>= cursor-loc magik-prefix-pos))
	    t
	  nil)))))

(provide 'magik-completion-prefixes)
;;; magik-completion-prefixes.el ends here
