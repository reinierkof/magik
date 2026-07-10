;;; magik-completion-cb-cache.el --- Contains all the functionality to communicate with the class browser and the results are stored here.  -*- lexical-binding: t; -*-

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
(require 'magik-completion-cb)

(defvar magik-completion--objects-source-cache-loaded nil
  "Tracks whether the object cache is loaded, for optional reset.")
(defvar magik-completion--globals-source-cache-loaded nil
  "Tracks whether the globals cache is loaded, for optional reset.")
(defvar magik-completion--conditions-source-cache-loaded nil
  "Tracks whether the conditions cache is loaded, for optional reset.")

(defvar magik-completion--objects-source-cache nil)
(defvar magik-completion--globals-source-cache nil)
(defvar magik-completion--conditions-source-cache nil)
(defvar magik-completion--class-method-source-cache nil)

(declare-function magik-completion--exemplar-near-point "magik-completion")

(defun magik-completion-invalidate-cache (&rest _args)
  "Reset the caches such that they will refill upon triggering the prefix."
  (interactive)
  (magik-completion--int-invalidate-cache))

(defun magik-completion--int-invalidate-cache (&rest _args)
  "Reset the caches such that they will refill upon triggering the prefix."
  (setq magik-completion--objects-source-cache-loaded nil
	magik-completion--globals-source-cache-loaded nil
	magik-completion--conditions-source-cache-loaded nil
	magik-completion--objects-source-cache nil
	magik-completion--globals-source-cache nil
	magik-completion--conditions-source-cache nil
	magik-completion--class-method-source-cache nil))

(defun magik-completion--load-source-caches ()
  "Check if the source caches are loaded and do init if needed."
  (when (not magik-completion--objects-source-cache-loaded)
    (magik-completion--objects-source-init))

  (when (not magik-completion--globals-source-cache-loaded)
    (magik-completion--globals-source-init))

  (when (not magik-completion--conditions-source-cache-loaded)
    (magik-completion--conditions-source-init)))

(defun magik-completion--method-candidates (prefix)
  "List of methods on a class.
Uses a cache variable `magik-completion--class-method-source-cache'.
All the methods beginning with the first character,
 are returned and stored in the cache.
Thus subsequent characters refining the match are handled by auto-complete.
the list of all possible matches, without recourse to the class browser.
PREFIX the current prefix"
  (let ((exemplar (magik-completion--exemplar-near-point))
	(short-prefix prefix))
    (if exemplar
	(progn
	  (setq short-prefix (concat exemplar "." (if (> (length short-prefix) 0) (substring short-prefix 0 1))))
	  (when (not (and magik-completion--class-method-source-cache
			  (equal (concat " " short-prefix) (car magik-completion--class-method-source-cache))))
	    (when (magik-completion--cb-start-process)
	      (setq magik-completion--class-method-source-cache (magik-completion--cb-method-candidates short-prefix)))))
      (setq magik-completion--class-method-source-cache nil))
    magik-completion--class-method-source-cache))

(defun magik-completion--objects-source-init (&optional reset)
  "Init function for obtaining all Magik Objects for use in completion.
If RESET is true, the cache is regenerated."
  (when (magik-completion--cb-start-process)
    (when (or (not magik-completion--objects-source-cache-loaded) reset)
      (let ((prefix "sw:object"))
	(setq magik-completion--objects-source-cache (magik-completion--cb-class-candidates prefix))
	(setq magik-completion--objects-source-cache-loaded t)))))

(defun magik-completion--globals-source-init (&optional reset)
  "Init function for obtaining all Magik Globals for use in completion.
If RESET is true, the cache is regenerated."
  (when (magik-completion--cb-start-process)
    (when (or (not magik-completion--globals-source-cache-loaded) reset)
      (let ((prefix "<global>."))
	(setq magik-completion--globals-source-cache (magik-completion--cb-method-candidates prefix))
	(setq magik-completion--globals-source-cache-loaded t)))))

(defun magik-completion--conditions-source-init (&optional reset)
  "Init function for obtaining all Magik Conditions for use in completion.
If RESET is true, the cache is regenerated."
  (when (magik-completion--cb-start-process)
    (when (or (not magik-completion--conditions-source-cache-loaded) reset)
      (let ((prefix "<condition>."))
	(setq magik-completion--conditions-source-cache (magik-completion--cb-method-candidates prefix))
	;; adds an : in front so the prefix works with the results.
	(setq magik-completion--conditions-source-cache
	      (mapcar (lambda (item) (concat ":" item)) (magik-completion--cb-method-candidates prefix)))
	(setq magik-completion--conditions-source-cache-loaded t)))))

(provide 'magik-completion-cb-cache)
;;; magik-completion-cb-cache.el ends here
