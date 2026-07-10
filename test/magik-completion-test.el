;;; magik-completion-test.el --- Tests for magik-completion.el  -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the pure-logic units of the `magik-completion' package
;; (ported from magik-company): annotation rendering, yasnippet
;; parameter-snippet insertion, prefix/context detection, CB output parsing,
;; and source-cache memoization.  Units that require a live tree-sitter
;; parse or a live GIS session (buffer-cache, treesitter-extras,
;; exemplar-types) are out of scope here and are covered by the manual
;; verification pass described in magik-completion/docs/architecture.md.

;;; Code:

(require 'test-helper)
;; `magik-mode', `magik-cb', and `magik-session' are required directly here
;; (not by `magik-completion' itself, to avoid a load cycle — see
;; `magik-completion.el's `magik-completion--enable') so the real
;; `magik-method-name-type', `magik-cb-in-keyword', and `magik-session-prompt'
;; are available to the units under test.
(require 'magik-mode)
(require 'magik-cb)
(require 'magik-session)
(require 'magik-completion)

(defmacro magik-completion-test--with-magik-buffer (text &rest body)
  "Insert a leading space then TEXT into a temp buffer and run BODY there.
Sets up Magik's underscore/question-mark-as-word-char syntax convention
(see `magik-base-mode-syntax-table' in magik-mode.el) so identifier-based
regexes behave as they would in a real Magik buffer, and the leading space
keeps prefix matches away from `point-min', which several of the prefix
functions treat as \"no buffer position before this\"."
  (declare (indent 1))
  `(with-temp-buffer
     (modify-syntax-entry ?_ "w")
     (modify-syntax-entry ?? "w")
     (insert " " ,text)
     ,@body))

;;; magik-completion--annotation

(defun magik-completion-test--method-candidate (&rest props)
  "Return a propertized \"a_method\" candidate string with PROPS applied.
PROPS is a plist of text-property name/value pairs."
  (let ((cand (copy-sequence "a_method")))
    (while props
      (put-text-property 0 (length cand) (car props) (cadr props) cand)
      (setq props (cddr props)))
    cand))

(ert-deftest magik-completion--annotation--no-properties-returns-nil ()
  "A candidate with no relevant properties gets no annotation."
  (should-not (magik-completion--annotation (magik-completion-test--method-candidate))))

(ert-deftest magik-completion--annotation--required-params ()
  "Required params are wrapped in angle brackets."
  (should (equal (magik-completion--annotation
                  (magik-completion-test--method-candidate 'arguments '("a" "b")))
                 "<a, b>")))

(ert-deftest magik-completion--annotation--optional-params-marked ()
  "The first optional param is prefixed with `_optional'."
  (should (equal (magik-completion--annotation
                  (magik-completion-test--method-candidate 'optional '("a")))
                 "<_optional a>")))

(ert-deftest magik-completion--annotation--gather-param-marked ()
  "The gather param is prefixed with `_gather'."
  (should (equal (magik-completion--annotation
                  (magik-completion-test--method-candidate 'gather '("args")))
                 "<_gather args>")))

(ert-deftest magik-completion--annotation--required-and-gather ()
  "Required and gather params are both included, in order."
  (should (equal (magik-completion--annotation
                  (magik-completion-test--method-candidate
                   'arguments '("a") 'gather '("args")))
                 "<a, _gather args>")))

(ert-deftest magik-completion--annotation--iter-marker-prefixed ()
  "Iterator methods get an `(I) ' prefix."
  (should (equal (magik-completion--annotation
                  (magik-completion-test--method-candidate 'arguments '("a") 'iter t))
                 "(I) <a>")))

(ert-deftest magik-completion--annotation--yasnippet-marker-prefixed ()
  "Yasnippet candidates get a `(Y) ' prefix."
  (should (equal (magik-completion--annotation
                  (magik-completion-test--method-candidate 'arguments '("a") 'yasnippet t))
                 "(Y) <a>")))

(ert-deftest magik-completion--annotation--params-hidden-when-disabled ()
  "No annotation is produced when `magik-completion-show-params-annotation' is nil."
  (let ((magik-completion-show-params-annotation nil))
    (should-not (magik-completion--annotation
                 (magik-completion-test--method-candidate 'arguments '("a"))))))

(ert-deftest magik-completion--annotation--optional-hidden-when-disabled ()
  "Optional params are excluded when the optional-annotation toggle is off."
  (let ((magik-completion-show-optional-params-annotation nil))
    (should (equal (magik-completion--annotation
                    (magik-completion-test--method-candidate
                     'arguments '("a") 'optional '("b")))
                   "<a>"))))

(ert-deftest magik-completion--annotation--gather-hidden-when-disabled ()
  "Gather params are excluded when the gather-annotation toggle is off."
  (let ((magik-completion-show-gather-param-annotation nil))
    (should (equal (magik-completion--annotation
                    (magik-completion-test--method-candidate
                     'arguments '("a") 'gather '("args")))
                   "<a>"))))

(ert-deftest magik-completion--annotation--exemplar-shows-package ()
  "Exemplar candidates show their (`prin1'-printed) package instead of
parameter info."
  (should (equal (magik-completion--annotation
                  (magik-completion-test--method-candidate 'kind 'exemplar 'package "sw"))
                 "\"sw\"")))

(ert-deftest magik-completion--annotation--exemplar-without-package-nil ()
  "Exemplar candidates without a package annotate to nil."
  (should-not (magik-completion--annotation
               (magik-completion-test--method-candidate 'kind 'exemplar))))

;;; magik-completion--doc-buffer

(ert-deftest magik-completion--doc-buffer--returns-buffer-with-documentation ()
  (let ((buf (magik-completion--doc-buffer
              (magik-completion-test--method-candidate 'documentation "Writes _self.\n"))))
    (should (bufferp buf))
    (should (equal (with-current-buffer buf (buffer-string)) "Writes _self.\n"))))

(ert-deftest magik-completion--doc-buffer--nil-when-no-documentation ()
  (should-not (magik-completion--doc-buffer
               (magik-completion-test--method-candidate 'kind 'method))))

;;; magik-completion--candidate-is-method

(ert-deftest magik-completion--candidate-is-method--method-kind ()
  (should (magik-completion--candidate-is-method
           (magik-completion-test--method-candidate 'kind 'method))))

(ert-deftest magik-completion--candidate-is-method--assign-method-kind ()
  (should (magik-completion--candidate-is-method
           (magik-completion-test--method-candidate 'kind 'assign-method))))

(ert-deftest magik-completion--candidate-is-method--global-kind ()
  (should (magik-completion--candidate-is-method
           (magik-completion-test--method-candidate 'kind 'global))))

(ert-deftest magik-completion--candidate-is-method--other-kind-is-nil ()
  (should-not (magik-completion--candidate-is-method
               (magik-completion-test--method-candidate 'kind 'slot))))

;;; magik-completion--insert-param-yasnippet / --insert-candidate-args-yasnippet

(defmacro magik-completion-test--with-insert-settings (params optional gather &rest body)
  "Eval BODY with the three insert-* toggles bound to PARAMS, OPTIONAL, GATHER."
  (declare (indent 3))
  `(let ((magik-completion-insert-params ,params)
         (magik-completion-insert-optional-params ,optional)
         (magik-completion-insert-gather-param ,gather))
     ,@body))

(defun magik-completion-test--expand-args (candidate-props buffer-text)
  "Insert BUFFER-TEXT, put point at its end, then run the args-yasnippet path.
CANDIDATE-PROPS is a plist as accepted by
`magik-completion-test--method-candidate', used to build the exit-function's
CANDIDATE argument.  Returns the resulting buffer string."
  (with-temp-buffer
    (yas-minor-mode 1)
    (insert buffer-text)
    (magik-completion--insert-candidate-args-yasnippet
     (apply #'magik-completion-test--method-candidate candidate-props))
    (buffer-string)))

(ert-deftest magik-completion--insert-candidate-args-yasnippet--insert-params-nil-no-op ()
  "When `magik-completion-insert-params' is nil, nothing is inserted."
  (magik-completion-test--with-insert-settings nil t t
    (should (equal (magik-completion-test--expand-args
                    '(kind method arguments ("a_stream")) "write_on")
                   "write_on"))))

(ert-deftest magik-completion--insert-candidate-args-yasnippet--not-a-method-no-op ()
  "Non-method candidates (e.g. slots) never get a param snippet."
  (magik-completion-test--with-insert-settings t t t
    (should (equal (magik-completion-test--expand-args
                    '(kind slot arguments ("a_stream")) "a_slot")
                   "a_slot"))))

(ert-deftest magik-completion--insert-candidate-args-yasnippet--required-only ()
  "Required params are expanded as a fresh parameter list."
  (magik-completion-test--with-insert-settings t t t
    (should (equal (magik-completion-test--expand-args
                    '(kind method arguments ("a_stream")) "write_on")
                   "write_on(a_stream)"))))

(ert-deftest magik-completion--insert-candidate-args-yasnippet--multiple-required ()
  "Multiple required params are comma-separated."
  (magik-completion-test--with-insert-settings t t t
    (should (equal (magik-completion-test--expand-args
                    '(kind method arguments ("thing" "iter_method")) "a_method")
                   "a_method(thing, iter_method)"))))

(ert-deftest magik-completion--insert-candidate-args-yasnippet--no-params-no-insert ()
  "A method with no arguments at all triggers no snippet expansion."
  (magik-completion-test--with-insert-settings t t t
    (should (equal (magik-completion-test--expand-args '(kind method) "a_method")
                   "a_method"))))

(ert-deftest magik-completion--insert-candidate-args-yasnippet--optional-included ()
  "Optional params are included when the optional toggle is on."
  (magik-completion-test--with-insert-settings t t t
    (should (equal (magik-completion-test--expand-args
                    '(kind method optional ("dataset_name")) "a_method")
                   "a_method(dataset_name)"))))

(ert-deftest magik-completion--insert-candidate-args-yasnippet--optional-excluded ()
  "Optional params are dropped when the optional toggle is off."
  (magik-completion-test--with-insert-settings t nil t
    (should (equal (magik-completion-test--expand-args
                    '(kind method optional ("dataset_name")) "a_method")
                   "a_method"))))

(ert-deftest magik-completion--insert-candidate-args-yasnippet--gather-included ()
  "The gather param is included when the gather toggle is on."
  (magik-completion-test--with-insert-settings t t t
    (should (equal (magik-completion-test--expand-args
                    '(kind method gather ("args")) "a_method")
                   "a_method(args)"))))

(ert-deftest magik-completion--insert-candidate-args-yasnippet--gather-excluded ()
  "The gather param is dropped when the gather toggle is off."
  (magik-completion-test--with-insert-settings t t nil
    (should (equal (magik-completion-test--expand-args
                    '(kind method gather ("args")) "a_method")
                   "a_method"))))

(ert-deftest magik-completion--insert-candidate-args-yasnippet--all-param-types ()
  "Required, optional, and gather params all appear in order when all are on."
  (magik-completion-test--with-insert-settings t t t
    (should (equal (magik-completion-test--expand-args
                    '(kind method arguments ("a") optional ("b") gather ("c")) "a_method")
                   "a_method(a, b, c)"))))

(ert-deftest magik-completion--insert-candidate-args-yasnippet--replaces-existing-close-paren ()
  "An already fully-typed pair of parens (point after the closing paren) has
its closing paren replaced rather than duplicated; note there is no leading
paren in this branch's own snippet text, so the opening paren must already
be present too (see `magik-completion--insert-param-yasnippet')."
  (magik-completion-test--with-insert-settings t t t
    (should (equal (magik-completion-test--expand-args
                    '(kind method arguments ("a_stream")) "write_on()")
                   "write_on(a_stream)"))))

;;; magik-completion--insert-candidate-yasnippet

(ert-deftest magik-completion--insert-candidate-yasnippet--expands-template ()
  "Accepting a yasnippet candidate deletes the candidate text and expands the
real yasnippet template registered under that key."
  (with-temp-buffer
    (yas-minor-mode 1)
    (yas-define-snippets 'fundamental-mode '(("my_snippet" "(${1:a})$0" "test")))
    (insert "my_snippet")
    (magik-completion--insert-candidate-yasnippet "my_snippet")
    (should (equal (buffer-string) "(a)"))))

;;; magik-completion--add-yasnippet-text-property

(ert-deftest magik-completion--add-yasnippet-text-property--no-matching-snippet-no-op ()
  "Candidates with no matching snippet are left untouched."
  (let ((cand (copy-sequence "no_such_snippet_xyz")))
    (magik-completion--add-yasnippet-text-property cand)
    (should-not (get-text-property 0 'yasnippet cand))))

;;; magik-completion--in-comment / --in-string

(ert-deftest magik-completion--in-comment--true-for-comment-line ()
  (with-temp-buffer
    (insert "  # a comment")
    (should (magik-completion--in-comment))))

(ert-deftest magik-completion--in-comment--false-for-code-line ()
  (with-temp-buffer
    (insert "a_variable")
    (should-not (magik-completion--in-comment))))

(ert-deftest magik-completion--in-string--true-inside-quotes ()
  (with-temp-buffer
    (modify-syntax-entry ?\" "\"")
    (insert "\"a string")
    (should (magik-completion--in-string))))

(ert-deftest magik-completion--in-string--false-outside-quotes ()
  (with-temp-buffer
    (modify-syntax-entry ?\" "\"")
    (insert "\"a string\" ")
    (should-not (magik-completion--in-string))))

;;; magik-completion--determine-cur-prefix

(ert-deftest magik-completion--determine-cur-prefix--simple-word ()
  (magik-completion-test--with-magik-buffer "some_variable"
    (should (equal (magik-completion--determine-cur-prefix) "some_variable"))))

(ert-deftest magik-completion--determine-cur-prefix--after-dot ()
  (magik-completion-test--with-magik-buffer "_self.wri"
    (should (equal (magik-completion--determine-cur-prefix) "wri"))))

(ert-deftest magik-completion--determine-cur-prefix--downcases ()
  (magik-completion-test--with-magik-buffer "Some_Method"
    (should (equal (magik-completion--determine-cur-prefix) "some_method"))))

;;; magik-completion--at-method-prefix

(ert-deftest magik-completion--at-method-prefix--after-self-dot ()
  (magik-completion-test--with-magik-buffer "_self.wri"
    (should (magik-completion--at-method-prefix))))

(ert-deftest magik-completion--at-method-prefix--no-dot-is-nil ()
  (magik-completion-test--with-magik-buffer "wri"
    (should-not (magik-completion--at-method-prefix))))

;;; magik-completion--at-raise-condition-prefix

(ert-deftest magik-completion--at-raise-condition-prefix--true ()
  (magik-completion-test--with-magik-buffer "condition.raise(:my_cond"
    (should (magik-completion--at-raise-condition-prefix))))

(ert-deftest magik-completion--at-raise-condition-prefix--false ()
  (magik-completion-test--with-magik-buffer "some_call(:my_arg"
    (should-not (magik-completion--at-raise-condition-prefix))))

;;; magik-completion--at-dynamic-prefix

(ert-deftest magik-completion--at-dynamic-prefix--true ()
  (magik-completion-test--with-magik-buffer "!my_dynam"
    (should (magik-completion--at-dynamic-prefix))))

(ert-deftest magik-completion--at-dynamic-prefix--false-for-plain-word ()
  (magik-completion-test--with-magik-buffer "my_word"
    (should-not (magik-completion--at-dynamic-prefix))))

;;; magik-completion--at-global-prefix / --at-object-prefix

(ert-deftest magik-completion--at-global-prefix--true-for-bare-word ()
  (magik-completion-test--with-magik-buffer "some_glo"
    (should (magik-completion--at-global-prefix))))

(ert-deftest magik-completion--at-global-prefix--false-after-dot ()
  (magik-completion-test--with-magik-buffer "_self.wri"
    (should-not (magik-completion--at-global-prefix))))

(ert-deftest magik-completion--at-object-prefix--true-for-bare-word ()
  (magik-completion-test--with-magik-buffer "sw_fol"
    (should (magik-completion--at-object-prefix))))

(ert-deftest magik-completion--at-object-prefix--true-for-packaged-name ()
  (magik-completion-test--with-magik-buffer "sw:fol"
    (should (magik-completion--at-object-prefix))))

;;; magik-completion--session-within-typeable-area

(ert-deftest magik-completion--session-within-typeable-area--true-after-prompt ()
  (with-temp-buffer
    (insert "Magik> some_inp")
    (should (magik-completion--session-within-typeable-area))))

(ert-deftest magik-completion--session-within-typeable-area--false-in-scrollback ()
  (with-temp-buffer
    (insert "Magik> old_output\nsome more scrollback text")
    (goto-char (point-min))
    (should-not (magik-completion--session-within-typeable-area))))

;;; magik-completion--cb-method-args

(defun magik-completion-test--cb-method-args (line)
  "Parse LINE (a CB args line, without leading space) via `magik-completion--cb-method-args'."
  (with-temp-buffer
    (insert " " line)
    (magik-completion--cb-method-args (point-min))))

(ert-deftest magik-completion--cb-method-args--no-args ()
  (should (equal (magik-completion-test--cb-method-args "") '(nil nil nil))))

(ert-deftest magik-completion--cb-method-args--required-only ()
  (should (equal (magik-completion-test--cb-method-args "a_stream")
                 '(("a_stream") nil nil))))

(ert-deftest magik-completion--cb-method-args--multiple-required ()
  (should (equal (magik-completion-test--cb-method-args "thing iter_method")
                 '(("thing" "iter_method") nil nil))))

(ert-deftest magik-completion--cb-method-args--optional-only ()
  (should (equal (magik-completion-test--cb-method-args "OPT dataset_name")
                 '(nil ("dataset_name") nil))))

(ert-deftest magik-completion--cb-method-args--gather-only ()
  (should (equal (magik-completion-test--cb-method-args "GATH args")
                 '(nil nil ("args")))))

(ert-deftest magik-completion--cb-method-args--optional-then-gather ()
  (should (equal (magik-completion-test--cb-method-args "OPT new_name OPT GATH new_properties")
                 '(nil ("new_name") ("new_properties")))))

(ert-deftest magik-completion--cb-method-args--required-and-gather ()
  (should (equal (magik-completion-test--cb-method-args "thing iter_method GATH args")
                 '(("thing" "iter_method") nil ("args")))))

;;; magik-completion--cb-add-method-properties

(ert-deftest magik-completion--cb-add-method-properties--required-args ()
  (let ((cand (copy-sequence "a_method")))
    (magik-completion--cb-add-method-properties cand "sw:a_class" '(("a_stream") nil nil) "" nil)
    (should (equal (get-text-property 0 'arguments cand) '("a_stream")))))

(ert-deftest magik-completion--cb-add-method-properties--optional-and-gather ()
  (let ((cand (copy-sequence "a_method")))
    (magik-completion--cb-add-method-properties cand "sw:a_class" '(nil ("opt") ("gath")) "" nil)
    (should (equal (get-text-property 0 'optional cand) '("opt")))
    (should (equal (get-text-property 0 'gather cand) '("gath")))))

(ert-deftest magik-completion--cb-add-method-properties--iter-classify ()
  (let ((cand (copy-sequence "a_method")))
    (magik-completion--cb-add-method-properties cand "sw:a_class" '(nil nil nil) "iter" nil)
    (should (get-text-property 0 'iter cand))))

(ert-deftest magik-completion--cb-add-method-properties--condition-class ()
  (let ((cand (copy-sequence "my_condition")))
    (magik-completion--cb-add-method-properties cand "<condition>" '(nil nil nil) "" nil)
    (should (eq (get-text-property 0 'kind cand) 'condition))))

(ert-deftest magik-completion--cb-add-method-properties--global-class ()
  (let ((cand (copy-sequence "my_global")))
    (magik-completion--cb-add-method-properties cand "<global>" '(nil nil nil) "" nil)
    (should (eq (get-text-property 0 'kind cand) 'global))))

(ert-deftest magik-completion--cb-add-method-properties--dynamic-global ()
  (let ((cand (copy-sequence "!my_dynamic!")))
    (magik-completion--cb-add-method-properties cand "<global>" '(nil nil nil) "" nil)
    (should (eq (get-text-property 0 'kind cand) 'dynamic))))

(ert-deftest magik-completion--cb-add-method-properties--documentation-strips-comment-markers ()
  (let ((cand (copy-sequence "a_method")))
    (magik-completion--cb-add-method-properties
     cand "sw:a_class" '(nil nil nil) "" "   ## Writes _self.\n   ## Returns _self.\n")
    (should (equal (get-text-property 0 'documentation cand)
                   "Writes _self.\nReturns _self.\n"))))

;;; magik-completion--cb-candidate-classes

(ert-deftest magik-completion--cb-candidate-classes--parses-package-and-class ()
  (with-temp-buffer
    (insert "sw:a_class\nsw:b_class\n")
    (let ((candidates (magik-completion--cb-candidate-classes)))
      (should (equal (sort (copy-sequence candidates) #'string<) '("a_class" "b_class")))
      (should (equal (get-text-property 0 'package (car (member "a_class" candidates))) "sw")))))

;;; magik-completion--cb-candidate-methods

(ert-deftest magik-completion--cb-candidate-methods--parses-basic-method ()
  (with-temp-buffer
    (insert "write_on  IN  sw:a_class B\n a_stream\n\n")
    (let ((candidates (magik-completion--cb-candidate-methods)))
      (should (equal candidates '("write_on")))
      (should (equal (get-text-property 0 'arguments (car candidates)) '("a_stream"))))))

(ert-deftest magik-completion--cb-candidate-methods--dedupes-repeated-candidates ()
  (with-temp-buffer
    (insert "write_on  IN  sw:a_class B\n a_stream\n\n")
    (insert "write_on  IN  sw:b_class B\n a_stream\n\n")
    (let ((candidates (magik-completion--cb-candidate-methods)))
      (should (equal candidates '("write_on"))))))

;;; magik-completion--load-source-caches / --int-invalidate-cache
;;; (source-init functions stubbed so no live GIS session is required)

(ert-deftest magik-completion--load-source-caches--populates-once-and-memoizes ()
  "Each source-init only runs once until the cache is invalidated."
  (let ((magik-completion--objects-source-cache-loaded nil)
        (magik-completion--globals-source-cache-loaded nil)
        (magik-completion--conditions-source-cache-loaded nil)
        (magik-completion--objects-source-cache nil)
        (magik-completion--globals-source-cache nil)
        (magik-completion--conditions-source-cache nil)
        (calls 0))
    (cl-letf (((symbol-function 'magik-completion--cb-start-process) (lambda () t))
              ((symbol-function 'magik-completion--cb-class-candidates)
               (lambda (_prefix) (cl-incf calls) '("an_object")))
              ((symbol-function 'magik-completion--cb-method-candidates)
               (lambda (_prefix) (cl-incf calls) '("a_global"))))
      (magik-completion--load-source-caches)
      (magik-completion--load-source-caches)
      (should (equal magik-completion--objects-source-cache '("an_object")))
      (should (equal magik-completion--globals-source-cache '("a_global")))
      (should (equal magik-completion--conditions-source-cache '(":a_global")))
      ;; objects (1 query) + globals (1 query) + conditions (queries twice,
      ;; discarding the first result — see `--conditions-source-init') = 4
      ;; underlying queries, none of them re-run on the second
      ;; `--load-source-caches' call.
      (should (= calls 4)))))

(ert-deftest magik-completion--int-invalidate-cache--resets-loaded-flags ()
  "Invalidating the cache clears both the cached data and the loaded flags."
  (let ((magik-completion--objects-source-cache-loaded t)
        (magik-completion--globals-source-cache-loaded t)
        (magik-completion--conditions-source-cache-loaded t)
        (magik-completion--objects-source-cache '("stale"))
        (magik-completion--globals-source-cache '("stale"))
        (magik-completion--conditions-source-cache '("stale"))
        (magik-completion--class-method-source-cache '("stale")))
    (magik-completion--int-invalidate-cache)
    (should-not magik-completion--objects-source-cache-loaded)
    (should-not magik-completion--globals-source-cache-loaded)
    (should-not magik-completion--conditions-source-cache-loaded)
    (should-not magik-completion--objects-source-cache)
    (should-not magik-completion--globals-source-cache)
    (should-not magik-completion--conditions-source-cache)
    (should-not magik-completion--class-method-source-cache)))

(provide 'magik-completion-test)
;;; magik-completion-test.el ends here
