;;; magik-company.el --- Magik backend for company-mode  -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Reinier Koffijberg

;; Author: Reinier Koffijberg <some@gmail.com>

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

;; See the README for more details.

;;; Code:

;;(require 'magik-mode)
(require 'yasnippet)
(require 'company)
(require 'magik-cb-ac)

(defgroup company-magik nil
  "Company back-end for Magik code completion."
  :group 'company
  :group 'magik)

(defvar magik-company--load-methods nil)
(defvar magik-company--load-conditions nil)
(defvar magik-company--load-dynamics nil)
(defvar magik-company--load-globals nil)
(defvar magik-company--load-objects nil)
(defvar magik-company--cur-prefix nil)

(defvar magik-company--objects-source-cache-loaded nil
  "Tracks whether the object cache is loaded, for optional reset.")
(defvar magik-company--globals-source-cache-loaded nil
  "Tracks whether the globals cache is loaded, for optional reset.")
(defvar magik-company--conditions-source-cache-loaded nil
  "Tracks whether the conditions cache is loaded, for optional reset.")

(defvar magik-company--objects-source-cache nil)
(defvar magik-company--globals-source-cache nil)
(defvar magik-company--conditions-source-cache nil)
(defvar magik-company--class-method-source-cache nil)

(defvar magik-company--objects-candidates nil)
(defvar magik-company--globals-candidates nil)
(defvar magik-company--conditions-candidates nil)
(defvar magik-company--class-method-candidates nil)

(defvar magik-company--typed-assignment-patterns
  '(("integer"    "\\s-*<<[ \t\n]*\\([-+]?[0-9]+\\)\\(\\s-+\\|$\\)")
    ("float"      "\\s-*<<[ \t\n]*\\([-+]?[0-9]*\\.[0-9]+\\)")
    ("char16_vector" "\\s-*<<[ \t\n]*\\(\"[^\"]*\"\\)")
    ("simple_vector" "\\s-*<<[ \t\n]*\\({.*\\)"))
  "List of assignment patterns for Magik variables.
Each entry is a double: (TYPE REGEX).")

(defvar magik-company--class-assignment-patterns
  '("\\s-*<<[ \t\n]*\\(\\S-+\\)\\.new")
  )

;;;###autoload
(defun company-magik (command &optional arg &rest ignored)
  "Company backend for magik-mode.
COMMAND, ARG, IGNORED"
  (interactive (list 'interactive))
  (cl-case command
    (prefix (magik-company--prefix))
    (candidates (magik-company--candidates))
    (annotation (magik-company--annotation arg))
    (kind (magik-company--kind arg))
                                        ;(doc-buffer (get-text-property 0 'document arg))
    (post-completion (magik-company--post-completion arg))
    (ignore-case (eq t t))
    )
  )

(defun magik-company--reload-cache ()
  "Reset the caches such that they will refill upon triggering the prefix."
  (interactive)
  (setq magik-company--objects-source-cache-loaded nil
        magik-company--globals-source-cache-loaded nil
        magik-company--conditions-source-cache-loaded nil
        )
  )
(defun magik-company--post-completion (candidate)
  "Insert parameters in snippet for CANDIDATE."
  (let ((snippet (magik-company--candidate-is-yasnippet candidate)))
    (if snippet
        (progn
          (delete-region (- (point) (length candidate)) (point))
          (yas-expand-snippet snippet))
      (progn
        (let ((arguments (magik-company--has-arguments candidate)))
          (if arguments (magik-company--insert-param-yassnippet arguments)))))))

(defun magik-company--annotation (candidate)
  (let* ((arguments (magik-company--has-arguments candidate))
        (formatted_args (if arguments
                           (concat "<" (string-join arguments ", ") ">")
                          "")))
    formatted_args))

(defun magik-company--kind (candidate)
  (cond
   ((member candidate magik-company--objects-candidates)  'variable)
   ((member candidate magik-company--globals-candidates) (if (string-prefix-p "!" candidate) 'event 'field))
   ((member candidate magik-company--conditions-candidates)  'property)
   ((member candidate magik-company--class-method-candidates) 'method)
   (t nil)))

(defun magik-company--has-arguments (candidate)
  (interactive)
  (let* ((doc (get-text-property 0 'document candidate))
         (excluded '("_gather" "_optional")))
    (when (and doc (string-match "(\\([^)]*\\))" (car (split-string doc "\n"))))
      (seq-remove (lambda (x) (member x excluded))
                  (split-string (match-string 1 doc) "[ ,]+" t)))))

(defun magik-company--prefix ()
  (if (and magik-mode-enabled
           (not (magik-company--in-comment))
           (not (magik-company--in-string)))
      (progn
        (setq magik-company--load-methods (magik-company--at-method-prefix))
        (setq magik-company--load-conditions (magik-company--at-raise-condition-prefix))
        (setq magik-company--load-dynamics (magik-company--at-dynamic-prefix))
        (setq magik-company--load-globals (magik-company--at-global-prefix))
        (setq magik-company--load-objects (magik-company--at-object-prefix))

        (let ((start (line-beginning-position))
              (end (point))
              (regex "[^a-zA-Z0-9:_!<^]+")
              result)
          (save-excursion
            (if (re-search-backward regex start t)
                (setq result (buffer-substring-no-properties (+ 1 (point)) end))
              (setq result (buffer-substring-no-properties start end)))
	    )
	  (setq magik-company--cur-prefix (downcase result))
          (downcase result)))
    (progn
      (setq magik-company--load-methods nil)
      (setq magik-company--load-conditions nil)
      (setq magik-company--load-dynamics nil)
      (setq magik-company--load-globals nil)
      (setq magik-company--load-objects nil)
      nil)))


(defun magik-company--candidates ()
  "Generate a list of completion candidates"
  (when (not magik-company--objects-source-cache-loaded)
    (magik-company--objects-source-init))

  (when (not magik-company--globals-source-cache-loaded)
    (magik-company--globals-source-init))

  (when (not magik-company--conditions-source-cache-loaded)
    (magik-company--conditions-source-init))

  (let ((magik-candidates '()))
    (when (or magik-company--load-globals
	            magik-company--load-dynamics)
      (setq magik-company--globals-candidates
            (magik-company--filter-candidates magik-company--globals-source-cache))
      (setq magik-candidates (append magik-candidates magik-company--globals-candidates)))

    (when magik-company--load-objects
      (setq magik-company--objects-candidates (magik-company--filter-candidates magik-company--objects-source-cache))
      (setq magik-candidates (append magik-candidates magik-company--objects-candidates)))

    (when magik-company--load-methods
      (setq magik-company--class-method-candidates (magik-company--filter-candidates (magik-company--method-candidates magik-company--cur-prefix)))
      (setq magik-candidates (append magik-candidates magik-company--class-method-candidates)))

    (when magik-company--load-conditions
      (setq magik-company--conditions-candidates (magik-company--filter-candidates magik-company--conditions-source-cache))
      (setq magik-candidates (append magik-candidates magik-company--conditions-candidates)))

    (setq magik-candidates (delete-dups magik-candidates))
    magik-candidates))

(defun magik-company--filter-candidates (candidates)
  "Filter CANDIDATES to include only those that start with magik current prefix."
  (or (cl-remove-if-not (lambda (candidate)
                          (string-prefix-p magik-company--cur-prefix candidate))
                        candidates)
      '()))

(defun magik-company--method-candidates (prefix)
  "List of methods on a class.
Uses a cache variable `magik-company--class-method-source-cache'.
All the methods beginning with the first character are returned and stored in the cache.
Thus subsequent characters refining the match are handled by auto-complete refining
the list of all possible matches, without recourse to the class browser.
PREFIX ..."
  (let ((exemplar (magik-company--exemplar-near-point))
	(short-prefix prefix))
    (if exemplar
	      (progn
          (setq short-prefix (concat exemplar "." (if (> (length short-prefix) 0) (substring short-prefix 0 1))))
          (if (not (and magik-company--class-method-source-cache
                        (equal (concat " " short-prefix) (car magik-company--class-method-source-cache))))
		          (progn
                (when (magik-cb-ac-start-process)
		             (setq magik-company--class-method-source-cache (magik-cb-ac-method-candidates short-prefix))))))))
          magik-company--class-method-source-cache
    )

(defun magik-company--exemplar-near-point ()
  "Get current exemplar near cursor position."
  (save-excursion
    (save-match-data
      (let ((pt (1- (magik-company--method-point)))
            variable
            exemplar)
        (goto-char pt)
        ;; Usefully skip over various syntax types:
        (if (not (zerop (skip-syntax-backward "w_().")))
            (setq variable (buffer-substring-no-properties (point) pt)))
        (if variable
            (setq exemplar
		  (let ((method-param-type (magik-company--method-param-type variable)))
		    (cond
		     ;; Self case
		     ((equal variable "_self")
		      (or (cadr (magik-current-method-name))
			  (file-name-sans-extension (buffer-name))))
		     ;; Check object source
		     ((member variable magik-company--objects-source-cache)
		      variable)
		     ;; Check typed assigned patterns
		     ((cl-loop for (type regex) in magik-company--typed-assignment-patterns
			             for match = (let ((result (magik-company--check-assignment-and-type variable regex type)))
					     result)
			             when match return match))
         ;; Check class assigned patterns
         ((cl-loop for regex in magik-company--class-assignment-patterns
                   for match = (let ((combined-regex (concat (regexp-quote variable) regex)))
                                 (save-excursion
                                   (when (re-search-backward combined-regex nil t)
                                     (let ((result (match-string 1)))
                                       result))))
                   when match return match))
		     ;; Check typed params (use the stored result)
		     ((not (null method-param-type))
		      method-param-type)
		     (t
		      nil)))))
	exemplar))))

(defun magik-company--method-param-type (param-name)
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

(defun magik-company--method-point ()
  "Detect if point is at . method point."
  (save-excursion
  (if (re-search-backward "\\(_self\\|_clone\\|\\S-\\)\\.\\(\\sw+\\)\\=" (line-beginning-position) t)
      (match-beginning 2))))

(defun magik-company--at-method-prefix ()
  "Detect if point is at . method point."
  (save-excursion
    (re-search-backward "\\(_self\\|_clone\\|\\S-\\)\\.\\(\\sw+\\)\\=" (line-beginning-position) t)))



(defun magik-company--at-raise-condition-prefix ()
  "Detect if the point is at a condition.raise."
  (save-excursion
    (if (re-search-backward "condition\\.raise(\\s-*:\\(\\sw+\\)\\=" nil t)
        t
      nil)))

(defun magik-company--at-dynamic-prefix ()
  "Detect if the point is at a !..! dynamic prefix."
  (save-excursion
    (if (and (re-search-backward "\\Sw\\(!\\sw*\\)\\=" nil t)
             (not (eq (following-char) ?.))
             (not (equal ":" (buffer-substring-no-properties (match-beginning 1) (1+ (match-beginning 1))))))
        t
      nil)))

(defun magik-company--at-global-prefix ()
  "Detect if the point is at a possible global."
  (save-excursion
    (if (re-search-backward "^\\s-*\\(\\sw+\\)\\=" (line-beginning-position) t)
        t
      nil)))

(defun magik-company--at-object-prefix ()
  "Detect if the point is at a possible object.
Allows for single words or two words connected with a ':'."
  (save-excursion
    (if (or
         (re-search-backward "\\b\\(\\sw+\\):\\(\\sw+\\)\\=" (line-beginning-position) t)
         (re-search-backward "\\b\\(\\sw+\\)\\=" (line-beginning-position) t))
        (not (or (eq (following-char) ?.)
                 (save-excursion
                   (goto-char (match-beginning 0))
                   (re-search-backward "\\." (line-beginning-position) t))))
      nil)))

(defun magik-company--objects-source-init (&optional reset)
  "Initialisation function for obtaining all Magik Objects for use in auto-complete-mode.
If RESET is true, the cache is regenerated."
  (when (magik-cb-ac-start-process)
    (when (or (not magik-company--objects-source-cache-loaded) reset)
      (let ((prefix "sw:object"))
        (setq magik-company--objects-source-cache (magik-cb-ac-class-candidates prefix))
        (setq magik-company--objects-source-cache-loaded t)))))

(defun magik-company--globals-source-init (&optional reset)
  "Initialisation function for obtaining all Magik Conditions for use in auto-complete-mode.
If RESET is true, the cache is regenerated."
   (when (magik-cb-ac-start-process)
    (when (or (not magik-company--globals-source-cache-loaded) reset)
      (let ((prefix "<global>."))
        (setq magik-company--globals-source-cache (magik-cb-ac-method-candidates prefix))
        (setq magik-company--globals-source-cache-loaded t)))))

(defun magik-company--conditions-source-init (&optional reset)
  "Initialisation function for obtaining all Magik Conditions for use in auto-complete-mode.
If RESET is true, the cache is regenerated."
   (when (magik-cb-ac-start-process)
    (when (or (not magik-company--conditions-source-cache-loaded) reset)
      (let ((prefix "<condition>."))
        (setq magik-company--conditions-source-cache (magik-cb-ac-method-candidates prefix))
        ;; adds an : infront so the prefix works with the results.
        (setq magik-company--conditions-source-cache
              (mapcar (lambda (item) (concat ":" item)) (magik-cb-ac-method-candidates prefix)))
        (setq magik-company--conditions-source-cache-loaded t)))))

(defun magik-company--in-comment ()
  "Check if the current line start is with #, igore whitespaces."
  (save-excursion
    (beginning-of-line)
    (looking-at-p "^[ \t]*#")))

(defun magik-company--in-string ()
  "Check if the current point is inside double quotes (\") or single quotes (')."
  (let ((syntax (syntax-ppss)))
    (nth 3 syntax)))

(defun magik-company--check-assignment-and-type (variable regex type)
  "Check if VARIABLE matches a REGEX pattern in the buffer.
If matched, return TYPE-OR-CLASS, otherwise nil."
  (save-excursion
    (if (re-search-backward (concat (regexp-quote variable) regex) nil t)
        (progn
            (if (stringp type)
                type
              (progn
                (message "Warning: type-or-class is not a valid string, it's: %s" type)
                nil)))
      nil)))

(defun magik-company--insert-param-yassnippet (list)
  "Insert a param yasnippet from LIST, each param is a tab and ends after the ')'."
  (interactive)
  (if (eq (char-before) ?\))
      (progn
        (delete-char -1)
        (yas-expand-snippet
         (concat (mapconcat (lambda (param) (format "${%s}" param)) list ", ") ")$0")
         ))
    (progn
      (yas-expand-snippet
         (concat (concat "(" (mapconcat (lambda (param) (format "${%s}" param)) list ", ") ")$0"))
      ))))

(defun magik-company--candidate-is-yasnippet (key)
  "Get the snippet called KEY in MODE's tables."
  (interactive)
  (let ((yas-choose-tables-first nil)
        (yas-choose-keys-first nil))
    (cl-find key (yas--all-templates
                  (yas--get-snippet-tables major-mode))
             :key #'yas--template-key :test #'string=))
  )
  (provide 'magik-comp-any)
;;; magik-comp-any.el ends here
