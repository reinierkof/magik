;;; magik-completion.el --- Magik backend for completion-at-point -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Reinier Koffijberg

;; Author: Reinier Koffijberg <reinierkof@gmail.com>

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This is a project for better auto-completion in Magik.

;;; Code:

(eval-and-compile
  (add-to-list 'load-path
               (file-name-directory
                (or load-file-name byte-compile-current-file buffer-file-name))))

(require 'magik-completion-annotation)
(require 'magik-completion-cb)
(require 'magik-completion-buffer-cache)
(require 'magik-completion-prefixes)
(require 'magik-completion-cb-cache)
(require 'magik-completion-exemplar-types)
(require 'magik-completion-yasnippet-handling)

;; `magik-cb' and `magik-session' both `require' `magik-mode', which in turn
;; `require's `magik-completion' — so they cannot be `require'd at load time
;; here without a cycle.  `magik-completion--enable' `require's them
;; lazily, at mode activation time, once `magik-mode' has finished loading.
(declare-function magik-transmit-region "magik-mode")
(declare-function magik-product-transmit-buffer "magik-product")
(declare-function magik-module-transmit-buffer "magik-module")
(declare-function magik-loadlist-transmit-buffer "magik-loadlist")
(declare-function magik-session-kill-process "magik-session")
(defvar magik-session-start-process-post-hook)

(defconst magik-completion--transmit-functions
  '(magik-product-transmit-buffer
    magik-module-transmit-buffer
    magik-loadlist-transmit-buffer
    magik-transmit-region)
  "Functions that send code to a Magik session and should invalidate the cache.")

(defvar magik-completion--objects-candidates nil)
(defvar magik-completion--globals-candidates nil)
(defvar magik-completion--snippets-candidates nil)
(defvar magik-completion--conditions-candidates nil)
(defvar magik-completion--class-method-candidates nil)
(defvar magik-completion--params-candidates nil)
(defvar magik-completion--variables-candidates nil)
(defvar magik-completion--slots-candidates nil)
(defvar magik-completion--exemplar-candidate nil)
(defvar magik-completion--initialised? nil)
(defvar magik-completion--session-mode 'magik-session-mode)
(defvar magik-completion--buffer-mode 'magik-ts-mode)

(defgroup magik-completion nil
  "Completion-at-point backend for Magik code completion."
  :group 'magik)

(defcustom magik-completion-blacklisted-candidates '()
  "Completion candidates that are ignored when found."
  :type '(repeat string)
  :group 'magik-completion)

(defcustom magik-completion-auto-enable nil
  "When non-nil, `magik-mode' and `magik-session-mode' enable
`magik-completion-mode' automatically."
  :type 'boolean
  :group 'magik-completion)

;;;###autoload
(define-minor-mode magik-completion-mode
  "Minor mode to enable the `Magik completion-at-point` backend."
  :lighter nil
  (if magik-completion-mode
      (magik-completion--enable)
    (magik-completion--disable)))

;;;###autoload
(defun magik-completion-setup ()
  "Enable `magik-completion-mode' in the current buffer."
  (magik-completion-mode 1))

(defun magik-completion--enable ()
  "Set up buffer for `magik-completion-mode`."
  (add-hook 'completion-at-point-functions #'magik-completion-capf nil t)
  (unless magik-completion--initialised?
    (require 'magik-cb)
    (require 'magik-session)
    (dolist (fn magik-completion--transmit-functions)
      (when (fboundp fn)
        (advice-add fn :after #'magik-completion-invalidate-cache)))
    (advice-add #'magik-session-kill-process :after #'magik-completion--exit-cb-buffers)
    (add-hook 'magik-session-start-process-post-hook #'magik-completion--kill-cb-ac-buffer)
    (setq magik-completion--initialised? t)))

(defun magik-completion--disable ()
  "Tear down `magik-completion-mode` in this buffer."
  (remove-hook 'completion-at-point-functions #'magik-completion-capf t)
  (dolist (fn magik-completion--transmit-functions)
    (when (fboundp fn)
      (advice-remove fn #'magik-completion-invalidate-cache))))

(defun magik-completion-capf ()
  "Completion-at-point function for `magik-mode' buffers and sessions."
  (let ((prefix (magik-completion--prefix)))
    (when prefix
      (list (- (point) (length prefix))
	    (point)
	    (magik-completion--candidates)
	    :exclusive 'no
	    :annotation-function #'magik-completion--annotation
	    :company-kind #'magik-completion--kind
	    :company-doc-buffer #'magik-completion--doc-buffer
	    :exit-function #'magik-completion--post-completion
            ))))

(defun magik-completion--prefix ()
  "Prefix and what to load based on those the current point."
  (if (or (magik-completion--in-comment)
	  (magik-completion--in-string)
	  (and (derived-mode-p magik-completion--session-mode)
	       (not (magik-completion--session-within-typeable-area))))
      (setq magik-completion-prefix-at-methods nil
	    magik-completion-prefix-at-conditions nil
	    magik-completion-prefix-at-dynamics nil
	    magik-completion-prefix-at-globals nil
	    magik-completion-prefix-at-slot nil
	    magik-completion-prefix-at-objects nil)
    (progn
      (setq magik-completion-prefix-at-methods (magik-completion--at-method-prefix)
	    magik-completion-prefix-at-conditions (magik-completion--at-raise-condition-prefix)
	    magik-completion-prefix-at-dynamics (magik-completion--at-dynamic-prefix)
	    magik-completion-prefix-at-globals (magik-completion--at-global-prefix)
	    magik-completion-prefix-at-slot (magik-completion--at-slot-prefix)
	    magik-completion-prefix-at-objects (magik-completion--at-object-prefix)))
    (magik-completion--determine-cur-prefix)))

(defun magik-completion--candidates ()
  "Generate a list of completion candidates."
  (magik-completion--load-source-caches)

  (let ((magik-candidates '()))
    (when (derived-mode-p magik-completion--buffer-mode)
      (setq magik-candidates (magik-completion--buffer-local-candidates magik-candidates)))

    (when (or magik-completion-prefix-at-globals
	      magik-completion-prefix-at-dynamics)
      (setq magik-completion--globals-candidates
	    (magik-completion--filter-candidates magik-completion--globals-source-cache magik-candidates))
      (setq magik-candidates (append magik-candidates magik-completion--globals-candidates)))

    (when magik-completion-prefix-at-objects
      (setq magik-completion--objects-candidates
	    (magik-completion--filter-candidates magik-completion--objects-source-cache magik-candidates))
      (setq magik-candidates (append magik-candidates magik-completion--objects-candidates))

      (setq magik-completion--snippets-candidates
	    (magik-completion--filter-candidates (magik-completion--candidate-yasnippets magik-completion-cur-prefix) magik-candidates))
      (setq magik-candidates (append magik-candidates magik-completion--snippets-candidates)))

    (when magik-completion-prefix-at-methods
      (setq magik-completion--class-method-candidates (magik-completion--filter-candidates (magik-completion--method-candidates magik-completion-cur-prefix) magik-candidates))
      (setq magik-candidates (append magik-candidates magik-completion--class-method-candidates)))

    (when magik-completion-prefix-at-conditions
      (setq magik-completion--conditions-candidates (magik-completion--filter-candidates magik-completion--conditions-source-cache magik-candidates))
      (setq magik-candidates (append magik-candidates magik-completion--conditions-candidates)))

    (dolist (candidate magik-candidates)
      (magik-completion--add-yasnippet-text-property candidate))

    (setq magik-candidates (cl-remove-if (lambda (candidate)
					   (member candidate magik-completion-blacklisted-candidates))
					 magik-candidates))

    ;; should not contain duplicates, because the filter takes it out.
    ;; in case we need it we can use this one.
    ;; (setq magik-candidates (delete-dups magik-candidates))
    magik-candidates))

(defun magik-completion--buffer-local-candidates(magik-candidates)
  "Add to the list of completion MAGIK-CANDIDATES with buffer-local functions."
  (magik-completion--update-buffer-caches)
  (when magik-completion-prefix-at-slot
    (setq magik-completion--slots-candidates (magik-completion--filter-candidates magik-completion--slots-cache magik-candidates))
    (setq magik-candidates (append magik-candidates magik-completion--slots-candidates)))

  (when magik-completion-prefix-at-objects
    (setq magik-completion--params-candidates (magik-completion--filter-candidates magik-completion--params-cache magik-candidates))
    (setq magik-candidates (append magik-candidates magik-completion--params-candidates))

    (setq magik-completion--variables-candidates (magik-completion--filter-candidates magik-completion--variables-cache magik-candidates))
    (setq magik-candidates (append magik-candidates magik-completion--variables-candidates))

    (setq magik-completion--exemplar-candidate (magik-completion--filter-candidates magik-completion--classname-cache magik-candidates))
    (setq magik-candidates (append magik-candidates magik-completion--exemplar-candidate)))
  magik-candidates)

(defun magik-completion--filter-candidates (new-candidates existing-candidates)
  "Filter NEW-CANDIDATES.
Include only candidates starting with current prefix.
and are not already present in EXISTING-CANDIDATES."
  (if (listp new-candidates)
      (progn
	(cl-remove-if-not (lambda (candidate)
			    (and (string-prefix-p magik-completion-cur-prefix candidate)
				 (not (member candidate existing-candidates))))
			  new-candidates))
    '()))

(defun magik-completion--post-completion (candidate &optional _status)
  "Insert parameters in snippet for CANDIDATE."
  (if (get-text-property 0 'yasnippet candidate)
      (magik-completion--insert-candidate-yasnippet candidate)
    (magik-completion--insert-candidate-args-yasnippet candidate)))

(defun magik-completion--kind (candidate)
  "Retrieve the kind for CANDIDATE."
  (if (get-text-property 0 'yasnippet candidate)
      'snippet
    (get-text-property 0 'kind candidate)))

(defun magik-completion--doc-buffer (candidate)
  "Return a buffer with documentation for CANDIDATE, or nil if none."
  (let ((doc (get-text-property 0 'documentation candidate)))
    (when (and doc (not (string-empty-p doc)))
      (with-current-buffer (get-buffer-create "*magik-completion-doc*")
        (erase-buffer)
        (insert doc)
        (goto-char (point-min))
        (current-buffer)))))

(provide 'magik-completion)
;;; magik-completion.el ends here
