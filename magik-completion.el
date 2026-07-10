;;; magik-completion.el --- Magik backend for completion-at-point -*- lexical-binding: t; -*-

;; Copyright (C) 2024-2025 Reinier Koffijberg

;; Author: Reinier Koffijberg <reinier.koffijberg@keronic.com>
;; Keywords: languages

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

;; This is a project for better auto-completion in Magik.
;;
;; See magik-completion/docs/architecture.md for an overview of how the
;; pieces below fit together:
;;  - Minor mode + `magik-completion-capf' (this file's first section) is the
;;    capf protocol implementation.
;;  - Prefix detection determines the context (method call, slot access,
;;    global, condition, dynamic, object) at point.
;;  - Annotation builds the string shown next to a candidate.
;;  - The class browser (CB) sections talk to a running GIS session's
;;    `method_finder' subprocess and cache the results.
;;  - The buffer-cache and tree-sitter sections provide buffer-local
;;    parameters/variables/slots, refreshed once per line change.
;;  - Exemplar-type inference guesses the Magik "type" of a variable at
;;    point.
;;  - Yasnippet handling looks up/expands snippets for candidates.

;;; Code:

(require 'treesit)
(require 'yasnippet)
(require 'magik-doc-gen)

;; `magik-cb' and `magik-session' both `require' `magik-mode', which in turn
;; `require's `magik-completion' — so they cannot be `require'd at load time
;; here without a cycle.  `magik-completion--enable' `require's them
;; lazily, at mode activation time, once `magik-mode' has finished loading.
(declare-function magik-transmit-region "magik-mode")
(declare-function magik-product-transmit-buffer "magik-product")
(declare-function magik-module-transmit-buffer "magik-module")
(declare-function magik-loadlist-transmit-buffer "magik-loadlist")
(declare-function magik-session-kill-process "magik-session")
(declare-function magik-cb-get-process-create "magik-cb")
(declare-function magik-cb-is-running "magik-cb")
(declare-function magik-cb-temp-file-name "magik-cb")
(declare-function magik-current-method-name "magik-mode")
;; `magik-yasnippet-prev-class-name' is defined by
;; snippets/magik-mode/.yas-setup.el, loaded ad hoc by yasnippet rather than
;; through a `require'-able feature, so there is no real require target for
;; it (a plain `(require 'magik-mode)' would not define it either, and
;; would create a load cycle since `magik-mode.el' pulls in
;; `magik-completion').
(declare-function magik-yasnippet-prev-class-name nil)
(defvar magik-session-start-process-post-hook)
(defvar magik-session-prompt)
(defvar magik-session-buffer)
(defvar magik-cb-filter-str)
(defvar magik-cb-coding-system)
(defvar magik-cb-in-keyword)

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

(defcustom magik-completion-show-optional-params-annotation t
  "When non-nil, show a method candidate's optional parameters in its annotation."
  :type 'boolean
  :group 'magik-completion)

(defcustom magik-completion-show-gather-param-annotation t
  "When non-nil, show a method candidate's gather parameter in its annotation."
  :type 'boolean
  :group 'magik-completion)

(defcustom magik-completion-show-params-annotation t
  "When non-nil, show a method candidate's parameters in its annotation."
  :type 'boolean
  :group 'magik-completion)

(defcustom magik-completion-insert-optional-params nil
  "When non-nil, insert a method candidate's optional parameters as a yasnippet."
  :type 'boolean
  :group 'magik-completion)

(defcustom magik-completion-insert-gather-param t
  "When non-nil, insert a method candidate's gather parameter as a yasnippet."
  :type 'boolean
  :group 'magik-completion)

(defcustom magik-completion-insert-params t
  "When non-nil, insert a method candidate's parameters as a yasnippet."
  :type 'boolean
  :group 'magik-completion)

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

;; State written by `magik-completion--prefix' (below) and read back by
;; `magik-completion--candidates'/`magik-completion--buffer-local-candidates'
;; within the same `magik-completion-capf' call; declared here (ahead of the
;; "Prefix detection" section) so both directions of that dependency compile
;; without free-variable warnings.
(defvar magik-completion-cur-prefix nil)
(defvar magik-completion-prefix-at-methods nil)
(defvar magik-completion-prefix-at-conditions nil)
(defvar magik-completion-prefix-at-dynamics nil)
(defvar magik-completion-prefix-at-globals nil)
(defvar magik-completion-prefix-at-objects nil)
(defvar magik-completion-prefix-at-slot nil)

;; Session-derived caches, populated by the "Class browser (CB) result
;; caching" section; declared here since `magik-completion--candidates'
;; (below) reads them directly.
(defvar magik-completion--objects-source-cache nil)
(defvar magik-completion--globals-source-cache nil)
(defvar magik-completion--conditions-source-cache nil)

;; Buffer-local caches, populated by the "Buffer-local caches" section;
;; declared here since `magik-completion--buffer-local-candidates' (below)
;; reads them directly.
(defvar magik-completion--params-cache nil)
(defvar magik-completion--variables-cache nil)
(defvar magik-completion--slots-cache nil)
(defvar magik-completion--classname-cache nil)

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

;;;; Prefix detection

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

;;;; Annotation

(defun magik-completion--annotation (candidate)
  "Create an annotation based on parameters of CANDIDATE."
  (let ((a-kind (get-text-property 0 'kind candidate))
	(param-functions (list (magik-completion--annotation-required-params candidate)
			       (magik-completion--annotation-optional-params candidate)
			       (magik-completion--annotation-gather-param candidate)))
	result)
    (setq result (if (and a-kind
			  (eq a-kind 'exemplar))
		     (progn (let ((package (get-text-property 0 'package candidate)))
			      (when package
				(prin1-to-string package))))
		   (progn (when magik-completion-show-params-annotation
			    (let ((args (delq nil (apply #'append param-functions))))
			      (when args
				(concat "<" (mapconcat #'identity args ", ") ">")))))))
    (when (get-text-property 0 'iter candidate) (setq result (concat "(I) " result)))
    (when (get-text-property 0 'yasnippet candidate) (setq result (concat "(Y) " result)))
    result))

(defun magik-completion--annotation-required-params (candidate)
  "Retrieve the arguments text property from CANDIDATE.
Also ensures it is a list of strings."
  (let ((params (get-text-property 0 'arguments candidate)))
    (when (listp params)  ; Ensure it's a list
      (mapcar #'identity params))))  ; Convert to a proper list of strings

(defun magik-completion--annotation-optional-params (candidate)
  "Retrieve the optional arguments text property from CANDIDATE.
Making the arguments italic."
  (when magik-completion-show-optional-params-annotation
    (let ((params (get-text-property 0 'optional candidate)))
      (when (and (listp params) params)
	(let ((annotated (mapcar (lambda (a-param)
				   (propertize (format "%s" a-param) 'face '(:slant italic)))
				 params)))
	  (setf (nth 0 annotated)
		(propertize (format "_optional %s" (nth 0 annotated))
			    'face '(:slant italic)))
	  annotated)))))

(defun magik-completion--annotation-gather-param (candidate)
  "Retrieve the gather arguments text property from CANDIDATE.
Making the arguments italic."
  (when magik-completion-show-gather-param-annotation
    (let ((params (get-text-property 0 'gather candidate)))
      (when (and (listp params) params)
	(let ((annotated (mapcar (lambda (a-param)
				   (propertize (format "%s" a-param) 'face '(:slant italic)))
				 params)))
	  (setf (nth 0 annotated)
		(propertize (format "_gather %s" (nth 0 annotated))
			    'face '(:slant italic)))
	  annotated)))))

;;;; Class browser (CB) buffer/process bookkeeping

(defconst magik-completion--cb-buffer "*cb-completion*"
  "The autocomplete class browser buffer associated with the GIS process.")

(defvar magik-completion--cb-process nil
  "Variable that references to the actual process.")

(defun magik-completion--kill-cb-ac-buffer ()
  "Kill the magik-completion buffer when starting a session."
  (when (get-buffer magik-completion--cb-buffer)
    (let ((magik-local-cb-ac-process (get-buffer-process (get-buffer magik-completion--cb-buffer))))
      (when magik-local-cb-ac-process
	(delete-process magik-local-cb-ac-process)
	(setq magik-completion--cb-process nil)))
    (kill-buffer magik-completion--cb-buffer)))

;;;; Class browser (CB) process communication

(defvar magik-completion--cb-max-methods 1000)
(defvar magik-completion--session-running nil)
(defvar magik-completion--cb-candidadates nil)

(defun magik-completion--exit-cb-buffers ()
  "Ensure cb buffers are deleted and status is reset."
  (setq magik-completion--session-running nil)
  (magik-completion--int-invalidate-cache)
  (magik-completion--force-kill-cb-completion-buffers))

(defun magik-completion--cb-filter (p s)
  "Process data coming back from the CB auto-complete buffer.
P ...
S ..."
  (with-current-buffer (process-buffer p)
    (unwind-protect
	(let ((buffer-read-only nil)
	      (coding-system-for-read magik-cb-coding-system)
	      fn)
	  (setq magik-cb-filter-str (concat magik-cb-filter-str s))
	  (save-match-data
	    (setq fn (cond ((string-match "\C-e" magik-cb-filter-str)
			    'magik-completion--cb-candidate-methods)
			   ((string-match "\C-c" magik-cb-filter-str)
			    'magik-completion--cb-candidate-classes)
			   (t
			    nil))))
	  (setq magik-cb-filter-str ""
		magik-completion--cb-candidadates (if fn
						   (progn
						     (insert-file-contents (magik-cb-temp-file-name p) nil nil nil t)
						     (funcall fn)))))
      (setq magik-cb-filter-str ""
	    magik-completion--cb-candidadates (if (eq magik-completion--cb-candidadates 'unset) nil magik-completion--cb-candidadates)))))

(defun magik-completion--cb-start-process ()
  "Start a Class Browser process for auto-complete-mode.
Returns t if the process was started or running, nil if there's an error."
  (if (process-live-p magik-completion--cb-process)
      t
    (let ((gis-buffer-name (magik-completion--cb-get-gis-buffer))
	  smallworld-gis)
      (when (and gis-buffer-name
		 (or magik-completion--session-running
		     (magik-completion--magik-session-started? gis-buffer-name)))
	(setq smallworld-gis (buffer-local-value 'magik-smallworld-gis (get-buffer gis-buffer-name)))
	(setq magik-completion--cb-process
	      (magik-cb-get-process-create
	       magik-completion--cb-buffer 'magik-completion--cb-filter smallworld-gis gis-buffer-name nil)))
      (if (process-live-p magik-completion--cb-process)
	  (progn
	    (magik-completion--int-invalidate-cache)
	    t)
	nil))))

(defun magik-completion--force-kill-cb-completion-buffers ()
  "Kill all buffers whose names start with *cb and end with completion*.
killing any associated processes without prompting."
  (dolist (buf (buffer-list))
    (let ((name (buffer-name buf)))
      (when (and name
		 (string-prefix-p "*cb" name)
		 (string-suffix-p "completion*" name))
	(when-let* ((proc (get-buffer-process buf)))
	  (delete-process proc))
	(kill-buffer buf)))))

(defun magik-completion--magik-session-started?(gis-buffer-name)
  "Check in the buffer from GIS-BUFFER-NAME whether session is initialized."
  (let ((session-started?
	 (with-current-buffer gis-buffer-name
	   (goto-char (point-max))
	   (let ((magik-prefix-pos (save-excursion (when (re-search-backward magik-session-prompt nil t)
						     (match-beginning 0))))
		 (magik-end-process-pos (save-excursion (when (re-search-backward "Process magik-session-process" nil t)
							  (match-beginning 0)))))
	     (if (and (number-or-marker-p magik-prefix-pos)
		      (or (not (number-or-marker-p magik-end-process-pos))
			  (> magik-prefix-pos magik-end-process-pos)))
		 t
	       nil)))))
    (if session-started?
	(magik-completion--method-finder-started? gis-buffer-name)
      nil)))

(defun magik-completion--method-finder-started?(gis-buffer-name)
  "Poke the magik-process in GIS-BUFFER-NAME if the method-finder is started."
  (let ((smallworld-gis (get-buffer-process (get-buffer gis-buffer-name))))
    (if smallworld-gis
	(progn
	  ;; send some magik code to start the method finder.
	  (process-send-string smallworld-gis "_if method_finder _isnt _unset\n_then\n  method_finder.lazy_start?\n_endif\n$\n")
	  (with-current-buffer gis-buffer-name
	    (goto-char (point-max))
	    (let ((method-finder-pos (save-excursion (when (re-search-backward "method_finder: loaded" nil t)
						       (match-beginning 0))))
		  (magik-end-process-pos (save-excursion (when (re-search-backward "Process magik-session-process" nil t)
							   (match-beginning 0)))))
	      (if (and (number-or-marker-p method-finder-pos)
		       (or (not (number-or-marker-p magik-end-process-pos))
			   (> method-finder-pos magik-end-process-pos)))
		  (progn (setq magik-completion--session-running t)
			 t)
		nil))))
      nil)))

(defun magik-completion--cb-get-gis-buffer ()
  "Find the gis buffer in current buffers if it is active.
Stores the buffer name in `magik-completion--cb-gis-buffer-name`
 or returns nil if no GIS buffer is found."
  (let ((gis-buffer-name nil))
    (cl-loop for buffer in (buffer-list)
	     do (if (and (stringp (buffer-name buffer))
                         (stringp magik-session-buffer)
			 (string-prefix-p magik-session-buffer (buffer-name buffer))
			 (get-buffer-process buffer))
		    (setq gis-buffer-name (buffer-name buffer))))
    gis-buffer-name))

(defun magik-completion--cb-candidate-methods ()
  "Return candidate methods matching `ac-prefix' from Method finder output."
  ;;TODO combine method definition with its signature.
  (let ((method (car nil))
	(ac-limit magik-completion--cb-max-methods))
    (setq method
	  (if (zerop (length method))
	      "\\sw"
	    (regexp-quote method)))
    (let ((i 0)
	  (regexp (concat "^\\(" method "\\S-*\\)" magik-cb-in-keyword "\\(\\S-+\\)\\s-+\\(.*\\)\n\\(.*\n\\)\n\\(\\( +##.*\n\\)*\\)"))
	  candidate
	  classify
	  class
	  args
	  documentation
	  candidates)
      (goto-char (point-min))
      (save-match-data
	(while (and (or (null ac-limit) (< i ac-limit))
		    (re-search-forward regexp nil t))
	  (setq candidate (match-string-no-properties 1)
		class     (match-string-no-properties 2)
		classify  (match-string-no-properties 3)
		args      (magik-completion--cb-method-args (match-beginning 4))
		documentation (match-string-no-properties 5))
	  (magik-completion--cb-add-method-properties candidate class args classify documentation)
	  (if (member candidate candidates)
	      nil ; already present
	    (setq candidates (append (list candidate) candidates)
		  i (1+ i)))))
      (nreverse candidates))))


(defun magik-completion--cb-method-args (pt)
  "Return method arguments from Class Browser at point PT."
  (save-excursion
    (goto-char pt)
    (save-match-data
      (let ((case-fold-search nil)
	    optional
	    args
	    gather
	    opt
	    name)
	(if (looking-at "$")
	    nil ; No arguments
	  (forward-char 1) ; space
	  (while (not (looking-at "$"))
	    (setq pt (point))
	    (cond ((looking-at "\\(OPT \\)?GATH \\(.*\\)")
		   (setq gather (list (buffer-substring-no-properties (match-beginning 2) (match-end 2))))
		   (goto-char (match-end 0)))
		  ((looking-at "OPT ")
		   (setq opt t)
		   (goto-char (match-end 0)))
		  ((> (skip-syntax-forward "w_") 0) ; found argument (may contain _ which may be classed as symbols.)
		   (setq name (list (buffer-substring-no-properties pt (point))))
		   (if opt
		       (setq optional (append optional name))
		     (setq args (append args name)))
		   (if (eq (following-char) ? )
		       (forward-char 1)))
		  (t ;catch all error
		   (message "Found unrecognised character at %d in %s" (point) (current-buffer))
		   (goto-char (end-of-line))))))
	(list args optional gather)))))

(defun magik-completion--cb-candidate-classes ()
  "Return candidate classes from Method finder output."
  (let ((i 0)
	(regexp (concat "\\(\\S-+:\\)\\(\\S-+\\)")) ; capture class name and its package
	candidate
	candidates
	package)
    (goto-char (point-min))
    (save-match-data
      (while (re-search-forward regexp nil t)
	(setq candidate (match-string-no-properties 2))
	(setq package (match-string-no-properties 1))
	(setq package (substring package 0 (1- (length package))))
	(put-text-property 0 (length candidate)  'kind 'exemplar candidate)
	(put-text-property 0 (length candidate)  'package package candidate)
	(save-match-data
	  ;; Use cl-pushnew to prevent duplicates
	  (cl-pushnew candidate candidates :test 'equal)
	  (setq i (1+ i))))
      candidates)))

(defun magik-completion--cb-add-method-properties (candidate class args classify documentation)
  "Return method documentation string.
CLASS ...
CANDIDATE ...
ARGS ...
CLASSIFY ...
DOCUMENTATION ..."
  (let* ((required (elt args 0))
	 (optional (elt args 1))
	 (gather (elt args 2))
	 (candidate-length (length candidate))
	 (method-signature (magik-method-name-type candidate))
	 (signature (cdr method-signature))
	 (signature-p (> (length signature) 0))
	 assignment)

    (cond ((zerop (length classify))
	   ;; only check for iter
	   ;; classify also contains (iter)
	   nil)
	  ((string-match "iter" classify)
	   (put-text-property 0 candidate-length 'iter t candidate))
	  ((equal (substring classify 0 1) "A")
	   (setq classify (concat "Advanced" (substring classify 1))))
	  ((equal (substring classify 0 1) "B")
	   (setq classify (concat "Basic" (substring classify 1))))
	  (t
	   ;;do nothing
	   nil))

    ;; Handle << assignment like signatures - take first required argument
    (if (and signature-p (equal (substring signature -1) "<"))
	(setq assignment (car required)
	      required (cdr required)))

    (when documentation
      (while (string-match "^ +## " documentation)
	(setq documentation (replace-match "" nil nil documentation)))
      (put-text-property 0 candidate-length 'documentation documentation candidate))

    (when required
      (put-text-property 0 candidate-length 'arguments required candidate))

    (when gather
      (put-text-property 0 candidate-length 'gather gather candidate))

    (when optional
      (put-text-property 0 candidate-length 'optional optional candidate))

    ;;Switch case
    (cond
     ((equal class "<condition>")
      (put-text-property 0 candidate-length 'kind 'condition candidate))

     ((equal class "<global>")
      ;; Global class is either a dynamic or a global proc
      (if (string-prefix-p "!" candidate)
	  (put-text-property 0 candidate-length 'kind 'dynamic candidate)
	(put-text-property 0 candidate-length 'kind 'global candidate)))

     ;; No signs after the method
     ((not signature-p)
      (put-text-property 0 candidate-length 'kind 'method candidate))

     ;; handles normal methods
     ;; Still need to find a way to have start signature in the candidate.
     ((equal (substring signature 0 1) "(")
      (put-text-property 0 candidate-length 'kind 'method candidate)
      (put-text-property 0 candidate-length 'start-signature "(" candidate)
      (put-text-property 0 candidate-length 'end-signature (substring signature 1) candidate))
     (assignment
      (put-text-property 0 candidate-length 'kind 'assignment-method candidate)
      (put-text-property 0 candidate-length 'assign-signature signature candidate)))))

(defun magik-completion--cb-method-candidates (prefix)
  "Return list of methods for a class matching PREFIX for auto-complete mode.
PREFIX is of the form \"CLASS\".\"METHOD_NAME_PREFIX\""
  (let ((magik-completion--cb-candidadates 'unset) ; use 'unset symbol since nil is also a valid return value.
	(ac-limit 1000)
	class method character)
    (save-match-data
      (cond ((null magik-completion--cb-process)
	     (setq magik-completion--cb-candidadates nil))
	    ((not (string-match "\\(\\S-+\\)\\.\\(.*\\)" prefix))
	     (setq magik-completion--cb-candidadates nil))
	    (t
	     (setq class (match-string-no-properties 1 prefix)
		   method (match-string-no-properties 2 prefix)
		   character (if (equal method "") method (substring method 0 1)))
	     (process-send-string magik-completion--cb-process
				  (concat "method_name ^" character "\n"
					  "unadd class \nadd class " class "\n"
					  "method_cut_off " (number-to-string ac-limit) "\n"
					  "override_flags\nshow_classes\nshow_args\nshow_comments\nprint_curr_methods\nshow_topics\n"))
	     (while (and (eq magik-completion--cb-candidadates 'unset)
			 (magik-cb-is-running nil magik-completion--cb-process))
	       (sleep-for 0.1))
	     (setq magik-completion--cb-candidadates (append (list (concat " " class "." character)) magik-completion--cb-candidadates)))))
    magik-completion--cb-candidadates))

(defun magik-completion--cb-class-candidates (prefix)
  "Return list of classes matching PREFIX for auto-complete mode."
  (let ((magik-completion--cb-candidadates 'unset)) ; use 'unset symbol since nil is also a valid return value.
    (cond ((null magik-completion--cb-process)
	   (setq magik-completion--cb-candidadates nil))
	  (t
	   (process-send-string magik-completion--cb-process
				(concat "dont_override_flags\npr_family " prefix "\n"))
	   (while (and (eq magik-completion--cb-candidadates 'unset)
		       (magik-cb-is-running nil magik-completion--cb-process))
	     (sleep-for 0.1))))
    magik-completion--cb-candidadates))

;;;; Class browser (CB) result caching

(defvar magik-completion--objects-source-cache-loaded nil
  "Tracks whether the object cache is loaded, for optional reset.")
(defvar magik-completion--globals-source-cache-loaded nil
  "Tracks whether the globals cache is loaded, for optional reset.")
(defvar magik-completion--conditions-source-cache-loaded nil
  "Tracks whether the conditions cache is loaded, for optional reset.")

(defvar magik-completion--class-method-source-cache nil)

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

;;;; Tree-sitter buffer analysis

(defvar magik-completion--ts-scope-keywords '("method" "block" "procedure"))
(defvar magik-completion--ts-parameterized-scope-keywords '("method" "procedure"))

(defun magik-completion--ts-node-type-in-scope (node type)
  "TYPE in a NODE."
  (let ((results '()))
    (when node
      (let ((stack (treesit-node-children node)))
	(while stack
	  (let ((current (pop stack)))
	    (when (string= (treesit-node-type current) type)
	      (push current results))
	    (when (not (member (treesit-node-type current)
			       magik-completion--ts-scope-keywords))
	      (setq stack (append (treesit-node-children current) stack)))))))
    (nreverse results)))

(defun magik-completion--ts-enclosing-scope (parameterized?)
  "Return the enclosing node of type ts-*-scope-keywords.
When PARAMETERIZED? then only the parameterized keywords"
  (let ((node (treesit-node-at (point)))
	(keyword-list (if parameterized?
			  magik-completion--ts-parameterized-scope-keywords
			magik-completion--ts-scope-keywords)))
    (while (and node
		(not (member (treesit-node-type node)
			     keyword-list)))
      (setq node (treesit-node-parent node)))
    node))

(defun magik-completion--ts-enclosing-method ()
  "Return the enclosing node of type method."
  (let ((node (treesit-node-at (point))))
    (while (and node
		(not (string= (treesit-node-type node) "method")))
      (setq node (treesit-node-parent node)))
    node))

(defun magik-completion--ts-exemplar-of-enclosing-method ()
  "Return the exemplar name of the enclosing method."
  (let ((node (magik-completion--ts-enclosing-method)))
    (when node
      (let ((results-node
	     (cdr (assoc 'exemplar
			 (treesit-query-capture node "(method exemplarname: (identifier) @exemplar)")))))
	(when results-node
	  (substring-no-properties (treesit-node-text results-node)))))))

(defun magik-completion--ts-parameters-in-scope ()
  "Get local buffer parameter from method/proc in scope."
  (let ((parameterized-scope (magik-completion--ts-enclosing-scope t)))
    (when parameterized-scope
      (let ((children (treesit-node-children parameterized-scope))
	    (results '())
	    (found nil))
	(dolist (child children)
	  (if (or (string= (treesit-node-text child) "\n")
		  (string= (treesit-node-text child) ")"))
	      (setq found t)
	    (when (and (not found)
		       (string= (treesit-node-type child) "argument"))
	      (push (substring-no-properties (treesit-node-text child)) results))))
	results))))

(defun magik-completion--ts-lhs-variables-in-assignment-node(node variables)
  "Lhs variables of an assignment NODE added in VARIABLES list."
  (let ((stack (magik-completion--ts-children-before-assignment node)))
    (while stack
      (let ((current (pop stack)))
	(when (string= (treesit-node-type current) "variable")
	  (push (substring-no-properties (treesit-node-text current)) variables))
	(setq stack (append (treesit-node-children current) stack))))
    variables))

(defun magik-completion--ts-children-before-assignment (node)
  "Return a list of NODE's children before << sign."
  (let ((children (treesit-node-children node))
	(result '())
	(found nil))
    (dolist (child children)
      (if (string= (treesit-node-text child) "<<")
	  (setq found t)
	(unless found
	  (push child result))))
    (nreverse result)))

(defun magik-completion--ts-import-variables-in-scope (node variables)
  "VARIABLES gained by the import statement in NODE."
  (when node
    (let ((stack (treesit-node-children node)))
      (while stack
	(let ((current (pop stack)))
	  (when (string= (treesit-node-type current) "import")
	    (push (substring-no-properties (treesit-node-text
					    (nth 1 (treesit-node-children current))))
		  variables))
	  (when (not (member (treesit-node-type current)
			     magik-completion--ts-scope-keywords))
	    (setq stack (append (treesit-node-children current) stack)))))))
  variables)

(defun magik-completion--ts-for-loop-variables-in-scope(node variables)
  "VARIABLES gained in the for loop statement in a NODE."
  (when (and (< (treesit-node-start node) (point))
	     (> (treesit-node-end  node) (point)))
    (let ((children (treesit-node-children node))
	  (found nil))
      (dolist (child children)
	(when (string= (treesit-node-text child) "over")
	  (setq found t))
	(when (and (not found)
		   (string= (treesit-node-type child) "identifier"))
	  (push (substring-no-properties (treesit-node-text child)) variables)))))
  variables)

(defun magik-completion--ts-for-local-variables-in-scope(node variables)
  "VARIABLES gained in the for loop statement in a NODE."
  (let ((children (treesit-node-children node))
	(found nil))
    (dolist (child children)
      (when (string= (treesit-node-text child) "<<")
	(setq found t))
      (when (and (not found)
		 (string= (treesit-node-type child) "identifier"))
	(push (substring-no-properties (treesit-node-text child)) variables))))
  variables)

(defun magik-completion--ts-exemplar-node-in-buffer-for (exemplar-name)
  "Exemplar node in buffer for EXEMPLAR-NAME."
  (cdr (assoc 'exemplar-node (treesit-query-capture
			      (treesit-buffer-root-node)
			      (format
			       "
((invoke receiver: (variable) @var (symbol) @sym) @exemplar-node
(#match %S @var) (#match %S @sym))"
			       "^def_slotted_exemplar$"
			       (concat "^:" exemplar-name "$"))))))

(defun magik-completion--ts-current-exemplar-node-with-locs ()
  "Exemplar node with the locations."
  (let* ((exemplar-node (magik-completion--ts-exemplar-node-in-buffer-for
			 (magik-completion--ts-exemplar-of-enclosing-method)))
	 (start-loc (and exemplar-node (treesit-node-start exemplar-node)))
	 (end-loc (and exemplar-node (treesit-node-end exemplar-node))))
    `((:node . ,exemplar-node)
      (:start . ,start-loc)
      (:end . ,end-loc))))

(defun magik-completion--ts-variables-in-scope ()
  "Return a list of all variable nodes within the enclosing fragment scope."
  (interactive)
  (let ((variables '())
	(scope (magik-completion--ts-enclosing-scope nil)))
    (when scope
      (setq variables (magik-completion--ts-import-variables-in-scope scope variables))
      (dolist (a-node (magik-completion--ts-node-type-in-scope scope "assignment"))
	(setq variables (magik-completion--ts-lhs-variables-in-assignment-node a-node variables)))
      (dolist (a-node (magik-completion--ts-node-type-in-scope scope "iterator"))
	(setq variables (magik-completion--ts-for-loop-variables-in-scope a-node variables)))
      (dolist (a-node (magik-completion--ts-node-type-in-scope scope "local"))
	(setq variables (magik-completion--ts-for-local-variables-in-scope a-node variables))))
    (delete-dups variables)))

;;;; Buffer-local caches (parameters, variables, slots, classname)

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

;;;; Exemplar-type inference

(defvar magik-completion--typed-assignment-patterns
  '(("integer"    "\\s-*<<[ \t\n]*\\([-+]?[0-9]+\\)\\(\\s-+\\|$\\)")
    ("float"      "\\s-*<<[ \t\n]*\\([-+]?[0-9]*\\.[0-9]+\\)")
    ("char16_vector" "\\s-*<<[ \t\n]*\\(\"[^\"]*\"\\)")
    ("simple_vector" "\\s-*<<[ \t\n]*\\({.*\\)"))
  "List of assignment patterns for Magik variables.
Each entry is a double: (TYPE REGEX).")

(defvar magik-completion--class-assignment-patterns
  '("\\s-*<<[ \t\n]*\\(\\S-+\\)\\.new"))

(defun magik-completion--try-method-exemplar-type (variable)
  "Retrieve the exemplar type based on what VARIABLE is."
  (let (exemplar-type)
    (setq exemplar-type
	  (or (magik-completion--self-case variable)
	      (magik-completion--check-object-source variable)
	      (magik-completion--super-case variable)
	      (magik-completion--check-typed-assigned-patterns variable)
	      (magik-completion--check-class-assigned-patterns variable)
	      (magik-completion--check-typed-params variable)))
    exemplar-type))

(defun magik-completion--self-case (variable)
  "Return the exemplar type if VARIABLE is '_self' or '_clone'."
  (when (or (equal variable "_self")
	    (equal variable "_clone")
	    (equal variable "_super"))
    (or (cadr (magik-current-method-name))
	(file-name-sans-extension (buffer-name)))))

(defun magik-completion--super-case (variable)
  "Return the super exemplar type if VARIABLE is `_super'."
  (when (string-match "_super(\\([a-zA-Z_]+\\))" variable)
    (match-string 1 variable)))

(defun magik-completion--check-object-source (variable)
  "Return VARIABLE if it exists in `magik-completion--objects-source-cache`."
  (when (and (listp magik-completion--objects-source-cache)
	     (member variable magik-completion--objects-source-cache))
    variable))

(defun magik-completion--check-typed-assigned-patterns (variable)
  "Return the matching type for VARIABLE based on typed assignment patterns."
  (cl-loop for (type regex) in magik-completion--typed-assignment-patterns
	   for match = (magik-completion--check-assignment-and-type variable regex type)
	   when match return match))

(defun magik-completion--check-class-assigned-patterns (variable)
  "Return the matching type for VARIABLE based on class assignment patterns."
  (cl-loop for regex in magik-completion--class-assignment-patterns
	   for match = (let ((combined-regex (concat (regexp-quote variable) regex)))
			 (save-excursion
			   (when (re-search-backward combined-regex nil t)
			     (match-string 1))))
	   when match return match))

(defun magik-completion--check-typed-params (variable)
  "Return the method parameter type for VARIABLE."
  (when-let* ((method-param-type (magik-completion--method-param-type variable)))
    method-param-type))

(defun magik-completion--method-param-type (param-name)
  "Search for the param-name in a method comment block and return the type.
PARAM-NAME ..."
  (save-excursion
    (let (start-loc method-loc)
      (setq start-loc (point))
      (setq method-loc (re-search-backward "\\(_method\\)" nil t))
      ;; If _method is found, proceed to search for the @param and type
      (if method-loc
	  (progn
	    (goto-char start-loc)
	    ;; Search for the @param with the given param-name
	    (if (re-search-backward
		 (format "##\\s-*@param\\s-*{\\([^}]+\\)}\\s-*%s" (regexp-quote param-name))
		 method-loc t)
		(match-string 1)
	      nil))))))

(defun magik-completion--check-assignment-and-type (variable regex type)
  "Check if VARIABLE matches a REGEX pattern in the buffer.
If matched, return TYPE, otherwise nil."
  (save-excursion
    (if (re-search-backward (concat (regexp-quote variable) regex) nil t)
	(progn
	  (if (stringp type)
	      type
	    (progn
	      (message "Warning: type-or-class is not a valid string, it's: %s" type)
	      nil)))
      nil)))

(defun magik-completion--exemplar-near-point ()
  "Get current exemplar-type near cursor position."
  (save-excursion
    (save-match-data
      (let ((pt (1- (magik-completion--method-point)))
	    variable
	    exemplar)
	(goto-char pt)
	;; Usefully skip over various syntax types:
	(if (not (zerop (skip-syntax-backward "w_.")))
	    (setq variable (buffer-substring-no-properties (point) pt)))
	(if variable
	    (setq exemplar (magik-completion--try-method-exemplar-type variable)))
	exemplar))))

(defun magik-completion--method-point ()
  "Detect if point is at . method point."
  (save-excursion
    (if (re-search-backward "\\(_self\\|_clone\\|\\S-\\)\\.\\(\\sw+\\)\\=" (line-beginning-position) t)
	(match-beginning 2))))

;;;; Yasnippet handling

(defun magik-completion--add-yasnippet-text-property(candidate)
  "If there is a snippet for CANDIDATE add a text property."
  (when (and (not (get-text-property 0 'yasnippet candidate))
	     (magik-completion--candidate-is-yasnippet candidate))
    (put-text-property 0 (length candidate) 'yasnippet t candidate)))

(defun magik-completion--insert-param-yasnippet (list)
  "Insert a param yasnippet from LIST, each param is a tab and ends after the ')'."
  (when list
    (if (eq (char-before) ?\))
	(progn
	  (delete-char -1)
	  (yas-expand-snippet
	   (concat (mapconcat (lambda (param) (format "${%s}" param)) list ", ") ")$0")))
      (progn
	(yas-expand-snippet
	 (concat (concat "(" (mapconcat (lambda (param) (format "${%s}" param)) list ", ") ")$0")))))))

(defun magik-completion--candidate-is-yasnippet (key)
  "Get the snippet called KEY in MODE's tables."
  (interactive)
  (let ((yas-choose-tables-first nil)
	(yas-choose-keys-first nil))
    (cl-find key (yas--all-templates
		  (yas--get-snippet-tables major-mode))
	     :key #'yas--template-key :test #'string=)))

(defun magik-completion--candidate-yasnippets (key)
  "Return all yasnippets whose keys start with KEY in the current major mode."
  (let ((yas-choose-tables-first nil)
	(yas-choose-keys-first nil))
    (mapcar #'yas--template-key
	    (seq-filter (lambda (tpl)
			  (string-prefix-p key (yas--template-key tpl)))
			(yas--all-templates
			 (yas--get-snippet-tables major-mode))))))

(defun magik-completion--insert-candidate-yasnippet(candidate)
  "Insert the yasnippet from CANDIDATE as post completion."
  (let ((a-snippet (magik-completion--candidate-is-yasnippet candidate)))
    (delete-region (- (point) (length candidate)) (point))
    (yas-expand-snippet a-snippet)))

(defun magik-completion--insert-candidate-args-yasnippet(candidate)
  "Check which type of arguments a CANDIDATE has.
Insert them depending on settings."
  (let ((arguments-to-insert nil))
    (when magik-completion-insert-params
      (when (magik-completion--candidate-is-method candidate)
	(setq arguments-to-insert (append arguments-to-insert
					  (get-text-property 0 'arguments candidate)))
	(when magik-completion-insert-optional-params
	  (setq arguments-to-insert (append arguments-to-insert
					    (get-text-property 0 'optional candidate))))
	(when magik-completion-insert-gather-param
	  (setq arguments-to-insert (append arguments-to-insert
					    (get-text-property 0 'gather candidate))))
	(magik-completion--insert-param-yasnippet arguments-to-insert)))))

(defun magik-completion--candidate-is-method(candidate)
  "Check if CANDIDATE is a magik method."
  (let ((a-kind (get-text-property 0 'kind candidate)))
    (or (eq a-kind 'method)
	(eq a-kind 'assign-method)
	(eq a-kind 'global))))

(provide 'magik-completion)
;;; magik-completion.el ends here
