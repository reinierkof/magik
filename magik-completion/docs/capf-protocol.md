# The completion-at-point (capf) protocol layer

This is the layer that implements Emacs's `completion-at-point-functions`
contract. It has no dependency on `company`. Everything it calls into
(prefix-context detection, candidate sources, annotation, snippet insertion)
is backend-agnostic and is documented in the other files in this folder.

## Files

- `magik-completion.el` — minor mode, capf function, candidate aggregation.
- `magik-completion-prefixes.el` — prefix string + context-flag detection (this
  is the direct analog of capf's "bounds of thing at point").
- `magik-completion-annotation.el` — per-candidate annotation string builder.

## Minor mode and registration (`magik-completion.el`)

```elisp
(define-minor-mode magik-completion-mode ...)
```

- `magik-completion--enable`: adds `magik-completion-capf` to the buffer-local
  `completion-at-point-functions`. On first activation *anywhere* (guarded by
  the global flag `magik-completion--initialised?`), it also wires up
  session-lifecycle glue that has nothing to do with the completion
  protocol:
  - `(advice-add #'magik-transmit-region :after #'magik-completion--int-invalidate-cache)`
  - `(advice-add #'magik-session-kill-process :after #'magik-completion--exit-cb-buffers)`
  - `(add-hook 'magik-session-start-process-post-hook #'magik-completion--kill-cb-ac-buffer)`
- `magik-completion--disable`: removes `magik-completion-capf` from
  `completion-at-point-functions`.

## The capf function

```elisp
(defun magik-completion-capf ()
  (let ((prefix (magik-completion--prefix)))
    (when prefix
      (list (- (point) (length prefix))
            (point)
            (magik-completion--candidates)
            :exclusive 'no
            :annotation-function #'magik-completion--annotation
            :company-kind #'magik-completion--kind
            :company-doc-buffer #'magik-completion--doc-buffer
            :exit-function #'magik-completion--post-completion))))
```

`magik-completion-capf` is added directly to `completion-at-point-functions`; it
returns `nil` when `magik-completion--prefix` decides there's nothing to
complete (so Emacs falls through to any other capf functions in the list),
or `(start end collection . props)` otherwise.

### Bounds and prefix → `magik-completion--prefix` (`magik-completion.el`)

Returns a string (the text to treat as the current prefix) or `nil` (don't
complete here). Also has a side effect: sets six global context-flag
variables (`magik-completion-prefix-at-methods`, `-at-conditions`,
`-at-dynamics`, `-at-globals`, `-at-slot`, `-at-objects`) that
`magik-completion--candidates` reads afterward.

Guard conditions that suppress completion entirely: inside a comment
(`magik-completion--in-comment`), inside a string (`magik-completion--in-string`),
or — in a session/REPL buffer only — outside the "typeable" area after the
last prompt (`magik-completion--session-within-typeable-area`).

Otherwise, each context flag is set by a corresponding predicate in
`magik-completion-prefixes.el` (see below), and the actual prefix string comes
from `magik-completion--determine-cur-prefix`.

`magik-completion--determine-cur-prefix` computes the prefix by regex-searching
backward and taking `buffer-substring-no-properties` up to point — the
resulting string is always the contiguous identifier substring ending
exactly at `(point)`. `magik-completion-capf` derives the `start` bound
arithmetically from this (`(- (point) (length prefix))`) rather than
threading a position through `magik-completion-prefixes.el` — no changes were
needed there.

### Candidates → `magik-completion--candidates` (`magik-completion.el`)

Not given the prefix as an argument — it reads the `magik-completion-cur-prefix`
global set during the preceding call to `magik-completion--prefix` within the
same `magik-completion-capf` invocation.

Aggregates, in order, gated by the context flags set above:

1. `magik-completion--buffer-local-candidates` — slots/params/variables/exemplar
   name (only when `derived-mode-p magik-completion--buffer-mode`, i.e.
   `magik-ts-mode`). See [buffer-analysis.md](buffer-analysis.md).
2. Globals/dynamics, from the session cache.
3. Objects (exemplars) plus yasnippets (treated as "objects" per the README),
   from the session cache and `magik-completion--candidate-yasnippets`.
4. Class methods, from the session cache, keyed off the exemplar type
   inferred near point.
5. Conditions, from the session cache.

Every list passes through `magik-completion--filter-candidates` (prefix match +
cross-source de-dup), then every surviving candidate is stamped with a
`yasnippet` text property if applicable
(`magik-completion--add-yasnippet-text-property`), and finally the whole list is
filtered against the `magik-completion-blacklisted-candidates` defcustom.

### `:annotation-function` → `magik-completion--annotation` (`magik-completion-annotation.el`)

Pure function of the candidate string's text properties (`kind`,
`arguments`, `optional`, `gather`, `iter`, `yasnippet`, `package`). Builds
strings like `<param1, _optional param2>`, prefixed with `(I)` for iterator
methods and/or `(Y)` for yasnippet candidates. No buffer/point dependency,
no side effects.

Customization: `magik-completion-show-params-annotation`,
`-show-optional-params-annotation`, `-show-gather-param-annotation`.

### `:company-kind` → `magik-completion--kind` (`magik-completion.el`)

`(candidate) -> symbol`. Returns `'snippet` if the candidate has a
`yasnippet` property, else its `kind` text property (`'method`, `'exemplar`,
`'slot`, `'variable`, `'parameter`, `'global`, `'condition`, `'dynamic`,
`'assign-method`). Exposed as `:company-kind` — an ecosystem convention (used
by e.g. `eglot`/`lsp-mode`'s capf functions) for icon-rendering front-ends
such as Corfu's `kind-icon` package, independent of whether `company` is
installed.

### `:company-doc-buffer` → `magik-completion--doc-buffer` (`magik-completion.el`)

`(candidate) -> buffer or nil`. Returns a buffer containing the candidate's
`documentation` text property, or `nil` when the candidate has none. Exposed
as `:company-doc-buffer` — the same ecosystem convention as `:company-kind`,
read by company-mode's `company-capf` backend and by Corfu's
`corfu-popupinfo`, again independent of whether `company` is installed. Only
method candidates (`magik-completion--cb-add-method-properties`) currently
carry a `documentation` property.

### `:exit-function` → `magik-completion--post-completion` (`magik-completion.el`)

Called as `(candidate status)` after the completion UI has already inserted
the candidate's text into the buffer (the `status` argument, one of
`finished`/`sole`/`exact`, is accepted but currently ignored). Dispatches to
yasnippet expansion — see [snippets.md](snippets.md).

## `magik-completion-prefixes.el` — prefix/context detection

Entirely buffer-local, regex/syntax-table based, no dependency on the
completion front end.

- `magik-completion--determine-cur-prefix` — the core "what is the user typing"
  function; direct analog of capf's "bounds of thing at point".
- `magik-completion--in-comment`, `magik-completion--in-string` — guard predicates.
- `magik-completion--at-method-prefix` (`obj.method`), `-at-raise-condition-prefix`
  (`condition.raise(:name`), `-at-slot-prefix` (`.slot_name`),
  `-at-dynamic-prefix` (`!name`), `-at-global-prefix` (bare identifier),
  `-at-object-prefix` (bare identifier or `package:class`) — one predicate
  per completion "context".
- `magik-completion--session-within-typeable-area` — session-buffer-only check
  that point is after the last prompt (depends on `magik-session-prompt`
  from `magik-mode`).
