;;; magik-ac.el --- autocomplete functionality

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

(require 'auto-complete)
(require 'magik-cb-ac)

;; A U T O - C O M P L E T E
;; _________________________

(eval-when-compile
  (defvar ac-sources)
  (defvar ac-prefix)
  (defvar ac-modes)
  )

(defvar magik-ac-sources
  (let ((default-sources '(
                           magik-ac-class-method-source
                           magik-ac-dynamic-source
                           magik-ac-global-source
                           magik-ac-object-source
                           magik-ac-raise-condition-source
                          )))
    (append (cl-remove-if (lambda (src)
                            (member src '(ac-source-abbrev
                                          ac-source-dictionary
                                          ac-source-words-in-same-mode-buffers))) ;; maybe let this one in ?
                          (when (and (boundp 'ac-sources) (listp ac-sources))
                            ac-sources))
            default-sources))
  "Auto-complete sources for Magik mode.")

;; consider enabling refresh using auto-complete's 10 minute refresh idle timer?
(defvar magik-ac-object-source-cache nil
  "Cache of all Magik Objects for use in auto-complete-mode.
Once initialised this variable is not refreshed.")

(defvar magik-ac-object-source
  '((init       . magik-ac-object-source-init)
    (candidates . magik-ac-object-source-cache)
    (prefix     . magik-object)
    (requires   . 3)
    (symbol     . "o"))
  "Auto-complete mode source definition for listing all Magik Objects.
Use auto-complete mode \"o\" symbol convention to represent an object.")

(defvar magik-ac-class-method-source-cache nil
  "Cache of all Magik methods on current class for use in auto-complete-mode.")

(defvar magik-ac-class-method-source
  '((init       . magik-ac-object-source-init)
    (candidates . magik-ac-class-method-source)
    (prefix     . magik-method)
    (symbol     . "f"))
  "Auto-complete mode source definition for listing methods on a given class.
Use auto-complete mode \"f\" symbol convention to represent a function, method.")

(defvar magik-ac-raise-condition-source-cache nil
  "Cache of all Magik Conditions for use in auto-complete-mode.")

(defvar magik-ac-raise-condition-source
  '((init       . magik-ac-raise-condition-source-init)
    (candidates . magik-ac-raise-condition-source-cache)
    (prefix     . magik-condition)
    (symbol     . "c"))
  "Auto-complete mode source definition for listing known conditions.
Uses auto-complete \"c\" symbol convention to represent a condition!")

(defvar magik-ac-global-source-cache nil
  "Cache of all Magik Globals for use in auto-complete-mode.
Once initialised this variable is not refreshed.")

(defvar magik-ac-dynamic-source
  '((init       . magik-ac-global-source-init)
    (candidates . magik-ac-global-source-cache)
    (prefix     . magik-dynamic)
    (symbol     . "d"))
  "Auto-complete mode source definition for listing Magik language dynamics.
Use auto-complete mode \"d\" symbol convention to represent.")

(defvar magik-ac-global-source
  '((init       . magik-ac-global-source-init)
    (candidates . magik-ac-global-source-cache)
    (prefix     . magik-ac-global-prefix)
					;(requires   . 3)
    (symbol     . "g"))
  "Auto-complete mode source definition for listing all Magik Globals.
Use auto-complete mode \"g\" symbol convention to represent a global.")

(defun magik-ac-check-assignment-and-type (variable regex type-or-class)
  "Check if VARIABLE matches a REGEX pattern in the buffer.
If matched, return TYPE-OR-CLASS, otherwise nil."
  (save-excursion
    (if (re-search-backward (concat (regexp-quote variable) regex) nil t)
        (progn
          (if (functionp type-or-class)
              (funcall type-or-class) ;; For dynamic class names
            (if (stringp type-or-class)
                type-or-class ;; Return the string
              (progn
                (message "Warning: type-or-class is not a valid string or function, it's: %s" type-or-class)
                nil))))
      nil))) ;; If no match is found, return nil

(defvar magik-ac-assignment-patterns
  '(("integer"    "\\s-*<<[ \t\n]*\\([-+]?[0-9]+\\)\\(\\s-+\\|$\\)" "integer")
    ("float"      "\\s-*<<[ \t\n]*\\([-+]?[0-9]*\\.[0-9]+\\)" "float")
    ("char16_vector" "\\s-*<<[ \t\n]*\\(\"[^\"]*\"\\)" "char16_vector")
    ("simple_vec" "\\s-*<<[ \t\n]*\\({.*\\)" "simple_vector")
    ("new-object" "\\s-*^?<<[ \t\n]*\\(\\S-+\\)\\.new"
     (lambda ()
       ;; Extract the class name from the matched group
       (buffer-substring-no-properties (match-beginning 1) (match-end 1)))))
  "List of assignment patterns for Magik variables.
Each entry is a triple: (TYPE REGEX RETURN-VALUE).")

(defun magik-ac-method-param-type (param-name)
  "Search for the param-name in a method comment block and return the type."
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

(defun magik-ac-exemplar-near-point ()
  "Get current exemplar near cursor position."
  (interactive)
  (save-excursion
    (save-match-data
      (let ((pt (1- (magik-ac-method-prefix)))
            variable
            exemplar)
        (goto-char pt)
        ;; Usefully skip over various syntax types:
        (if (not (zerop (skip-syntax-backward "w_().")))
            (setq variable (buffer-substring-no-properties (point) pt)))
        (if variable
            (setq exemplar (cond
                            ;; Self case
                            ((equal variable "_self")
                             (or (cadr (magik-current-method-name))
                                 (file-name-sans-extension (buffer-name))))
                            ;; Check object source
                            ((member variable magik-ac-object-source-cache)
                             variable)
                            ;; Check assigned patterns
                            ((cl-loop for (a_type regex return-value) in magik-ac-assignment-patterns
                                      for match = (let ((result (magik-ac-check-assignment-and-type variable regex return-value)))
                                                    result)
                                      when match return match))
			    ;; Check typed params
			    ((magik-ac-method-param-type variable)
			     (magik-ac-method-param-type variable))
                            (t
                             nil))))
	(message "exem: %s" exemplar)
	exemplar))))

(defun magik-ac-class-method-source ()
  "List of methods on a class.
Uses a cache variable `magik-ac-class-method-source-cache'.
All the methods beginning with the first character are returned and stored in the cache.
Thus subsequent characters refining the match are handled by auto-complete refining
the list of all possible matches, without recourse to the class browser."
  (let ((exemplar (magik-ac-exemplar-near-point))
	(ac-prefix ac-prefix))
    (if exemplar
	(progn
	  (setq ac-prefix (concat exemplar  "." (if (> (length ac-prefix) 0) (substring ac-prefix 0 1))))
	  (if (and magik-ac-class-method-source-cache
		   (equal (concat " " ac-prefix) (car magik-ac-class-method-source-cache)))
	      ;; Re-use cache.
	      magik-ac-class-method-source-cache
	    ;; reset cache
	    (setq magik-ac-class-method-source-cache (magik-cb-ac-method-candidates)))))))

(defun magik-ac-object-source-init ()
  "Initialisation function for obtaining all Magik Objects for use in auto-complete-mode."
  (if (magik-cb-ac-start-process)
      (let ((ac-prefix "sw:object"))
	(setq magik-ac-object-source-cache (magik-cb-ac-class-candidates)))))

(defun magik-ac-object-prefix ()
  "Detect if point is at a possible object, allowing for a package: prefix."
  (let (pt)
    (cond
     ((re-search-backward "\\(\\sw+:\\)\\(\\sw+\\)\\=" (line-beginning-position) t)
      (match-beginning 2))
     ((and (re-search-backward "\\Sw\\(\\sw+\\)\\=" (line-beginning-position) t)
	   (not (eq (following-char) ?.))
	   (setq pt (match-beginning 1))
	   (not (equal ":" (buffer-substring-no-properties pt (1+ pt)))))
      pt)
     (t nil))))

(defun magik-ac-global-prefix ()
  "Detect if point is at a possible global."
  (let (pt)
    (cond
     ((and (re-search-backward "^\\s-*\\(\\sw+\\)\\=" (line-beginning-position) t)
	   (setq pt (match-beginning 1)))
      pt)
     (t nil))))

(defun magik-ac-method-prefix ()
  "Detect if point is at . method point."
  (if (re-search-backward "\\(_self\\|_clone\\|\\S-\\)\\.\\(\\sw+\\)\\=" nil t)
      (match-beginning 2)))

(defun magik-ac-raise-condition-source-init ()
  "Initialisation function for obtaining all Magik Conditions for use in auto-complete-mode.
Once initialised this variable is not refreshed."
  (if (magik-cb-ac-start-process)
      (let ((ac-prefix "<condition>."))
	(if magik-ac-raise-condition-source-cache
	    ;; consider enabling refresh using auto-complete's 10 minute refresh idle timer?
	    magik-ac-raise-condition-source-cache
	  (setq magik-ac-raise-condition-source-cache (magik-cb-ac-method-candidates))))))

(defun magik-ac-raise-condition-prefix ()
  "Detect if point is at a condition.raise."
  (if (re-search-backward "condition\\.raise(\\s-*:\\(\\sw+\\)\\=" nil t)
      (match-beginning 1)))

(defun magik-ac-global-source-init ()
  "Initialisation function for obtaining all Magik Conditions for use in auto-complete-mode.
Once initialised this variable is not refreshed."
  (if (magik-cb-ac-start-process)
      (let ((ac-prefix ac-prefix))
	(if magik-ac-global-source-cache
	    ;; consider enabling refresh using auto-complete's 10 minute refresh idle timer?
	    magik-ac-global-source-cache
	  (setq magik-ac-global-source-cache (magik-cb-ac-method-candidates))))))

(defun magik-ac-dynamic-prefix ()
  "Detect if point is at !..! dynamic point."
  (let (pt)
    (if (and (re-search-backward "\\Sw\\(!\\sw*\\)\\=" nil t)
	     (not (eq (following-char) ?.))
	     (setq pt (match-beginning 1))
	     (not (equal ":" (buffer-substring-no-properties pt (1+ pt)))))
	pt)))

(defun magik-ac-complete ()
  "Auto-complete command for Magik entities."
  (interactive)
  (let ((ac 'auto-complete))
    (when (fboundp ac)
      (funcall ac '(
		    magik-ac-class-method-source
		    magik-ac-raise-condition-source
		    magik-ac-dynamic-source
		    magik-ac-object-source
		    magik-ac-global-source)))))

;; Auto-complete configuration
(defun magik-ac-configuration ()
  "Configure Magik package for auto-complete mode."
  (unless (assoc 'magik-dynamic ac-prefix-definitions)
    (ac-define-prefix 'magik-dynamic 'magik-ac-dynamic-prefix))
  (unless (assoc 'magik-condition ac-prefix-definitions)
    (ac-define-prefix 'magik-condition 'magik-ac-raise-condition-prefix))
  (unless (assoc 'magik-object ac-prefix-definitions)
    (ac-define-prefix 'magik-object 'magik-ac-object-prefix))
  (unless (assoc 'magik-method ac-prefix-definitions)
    (ac-define-prefix 'magik-method 'magik-ac-method-prefix))
  (unless (assoc 'magik-global ac-prefix-definitions)
    (ac-define-prefix 'magik-global 'magik-ac-global-prefix))
  (unless (member 'magik-mode ac-modes)
    (setq ac-modes (append (list 'magik-mode) ac-modes))))

(with-eval-after-load 'auto-complete
  (magik-ac-configuration))

(provide 'magik-ac)
;;; magik-ac.el ends here
