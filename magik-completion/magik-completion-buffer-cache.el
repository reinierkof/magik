;;; magik-completion-buffer-cache.el --- Contains the methods to retrieve the parameters & slots from the current buffer  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Author:  <reinier.koffijberg@RDS>
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
(require 'magik-completion-treesitter-extras)
(require 'magik-doc-gen)

;; `magik-yasnippet-prev-class-name' is defined by
;; snippets/magik-mode/.yas-setup.el, loaded ad hoc by yasnippet rather than
;; through a `require'-able feature, so there is no real require target for
;; it (a plain `(require 'magik-mode)' would not define it either, and
;; would create a load cycle since `magik-mode.el' pulls in
;; `magik-completion').
(declare-function magik-yasnippet-prev-class-name nil)

(defvar magik-completion--params-cache nil)
(defvar magik-completion--variables-cache nil)
(defvar magik-completion--slots-cache nil)
(defvar magik-completion--classname-cache nil)

(defvar magik-completion--last-line-number 0)

(defun magik-completion--update-buffer-caches ()
  "Update all local buffer caches."
  (when (/= magik-completion--last-line-number (line-number-at-pos))
    (setq magik-completion--last-line-number (line-number-at-pos))
    (magik-completion--load-params-cache)
    (magik-completion--load-variables-cache)
    (magik-completion--load-slots-cache)
    (magik-completion--load-classname-cache)))

(defun magik-completion--load-params-cache ()
  "Load method parameters into the cache and add the parameter kind property."
  (setq magik-completion--params-cache
	(mapcar (lambda (el) (propertize el 'kind 'parameter))
		(magik-completion--method-parameters))))

(defun magik-completion--load-variables-cache ()
  "Load local variables into the cache and add the variable kind property."
  (setq magik-completion--variables-cache
	(mapcar (lambda (el) (propertize el 'kind 'variable))
		(magik-completion--local-variables))))

(defun magik-completion--load-slots-cache ()
  "Load exemplar slots into the cache and add the slot kind property."
  (setq magik-completion--slots-cache
	(mapcar (lambda (el) (propertize el 'kind 'slot))
		(magik-completion--exemplar-slots))))

(defun magik-completion--load-classname-cache ()
  "Load the previous class name into the cache and add the exemplar kind property."
  (setq magik-completion--classname-cache
	(let ((prev-class-name (magik-yasnippet-prev-class-name)))
	  (when prev-class-name
	    (list (propertize prev-class-name 'kind 'exemplar))))))

(defun magik-completion--local-variables ()
  "Gather local variables in the current scope."
  (magik-completion--ts-variables-in-scope))

(defun magik-completion--method-parameters ()
  "Get local parameters in the current scope."
  (magik-completion--ts-parameters-in-scope))

(defun magik-completion--exemplar-slots ()
  "Retrieve the slots from a exemplar or mixin."
  (let ((slots '())
	(exemplar-data (magik-completion--ts-current-exemplar-node-with-locs)))
    (when (alist-get :node exemplar-data)
      (let ((slotted-loc (alist-get :start exemplar-data))
	    (dollar-loc (alist-get :end exemplar-data)))
	(save-excursion
	  (goto-char slotted-loc)
	  (while (re-search-forward "{\\s-*:\\(\\sw+\\)\\s-*,\\s-*\\(_unset\\)\\s-*" dollar-loc t)
	    (push (match-string 1) slots)))))
    slots))

(provide 'magik-completion-buffer-cache)
;;; magik-completion-buffer-cache.el ends here
