# Buffer analysis: tree-sitter scope parsing and type inference

This layer never talks to the GIS session (except for one cache read in
`exemplar-types.el`) and has no dependency on the completion front end. It is
pure buffer/point analysis and was reused unchanged by `magik-completion-capf`.

## Files

- `magik-completion-treesitter-extras.el` — tree-sitter queries over the current
  buffer's Magik parse tree.
- `magik-completion-buffer-cache.el` — buffer-local memoization of the above,
  refreshed once per line change.
- `magik-completion-exemplar-types.el` — heuristic type/exemplar inference for a
  variable at point.

## `magik-completion-treesitter-extras.el`

Relies on `magik-ts-mode` (from `magik-mode`) having already created/attached
a tree-sitter parser to the buffer; this file only calls generic
`treesit-*` primitives against whatever parser is active.

- Scope boundaries: `"method"`, `"block"`, `"procedure"` node types
  (`magik-completion--ts-scope-keywords`); `"method"`/`"procedure"` are the
  subset that can carry parameters (`-ts-parameterized-scope-keywords`).
- `magik-completion--ts-enclosing-scope` — walks parents from
  `(treesit-node-at (point))` up to the nearest scope-boundary node.
- `magik-completion--ts-node-type-in-scope` — downward walk collecting all
  descendant nodes of a given type, **not** descending into nested scope
  boundaries (so an inner method/block/procedure's variables don't leak into
  the outer scope's candidate list).
- `magik-completion--ts-variables-in-scope` (interactive) — the single top-level
  entry point answering "what variables can be completed right now". Combines,
  within the enclosing (non-parameterized) scope:
  - `_import` variables (`-ts-import-variables-in-scope`),
  - `<<` assignment LHS targets (`-ts-lhs-variables-in-assignment-node` /
    `-ts-children-before-assignment`),
  - loop variables from `_for ... _over ...` (`-ts-for-loop-variables-in-scope`,
    **only while point is physically inside that loop's node range** — loop
    vars go out of scope for completion once you leave the loop body),
  - `_local` declarations (`-ts-for-local-variables-in-scope`).
- `magik-completion--ts-parameters-in-scope` — separate from the above; walks
  the enclosing **parameterized** scope's direct children, collecting
  `"argument"`-typed nodes until the parameter list closes (stops at a
  newline or `)` token, since `argument` nodes can also appear inside
  optional/gather bodies).
- `magik-completion--ts-exemplar-of-enclosing-method` — finds the enclosing
  `method` node and queries its `exemplarname` field — "what class is the
  current method defined on" (used to resolve `_self`).
- `magik-completion--ts-exemplar-node-in-buffer-for` /
  `-ts-current-exemplar-node-with-locs` — locates a class's
  `def_slotted_exemplar(:name, ...)` invocation in the buffer via a
  tree-sitter query, returning its start/end buffer positions. Note: this
  only locates the *region*; actual slot-name extraction is done by a plain
  regex search over that region in `magik-completion-buffer-cache.el`, not by a
  further tree-sitter query.

Not implemented in this file (documented as a gap, not a bug): `_self`-to-type
resolution beyond "what class is this method on" (see exemplar-types.el
below), and `@param {Type}` doc-comment parsing (also in exemplar-types.el).

## `magik-completion-buffer-cache.el`

Buffer-local caches, refreshed via a cheap heuristic rather than on every
keystroke:

- `magik-completion--update-buffer-caches` — recomputes all four caches only
  `(when (/= magik-completion--last-line-number (line-number-at-pos)))`, i.e.
  once per line change. Called from `magik-completion--buffer-local-candidates`
  in `magik-completion.el` on each completion attempt.
- `magik-completion--params-cache` ← `magik-completion--ts-parameters-in-scope`,
  tagged `kind='parameter`.
- `magik-completion--variables-cache` ← `magik-completion--ts-variables-in-scope`,
  tagged `kind='variable`.
- `magik-completion--slots-cache` ← `magik-completion--exemplar-slots` (regex scan
  for `{:slot_name, _unset}` within the exemplar-node bounds located by
  tree-sitter above), tagged `kind='slot`.
- `magik-completion--classname-cache` ← `magik-yasnippet-prev-class-name`, an
  **external function from `magik-mode`'s yasnippet snippet setup**
  (`snippets/magik-mode/.yas-setup.el`, not `magik-mode.el` itself or
  `magik-doc-gen` despite the file's `(require 'magik-doc-gen)`, which
  appears unused/vestigial), tagged `kind='exemplar`.

This once-per-line throttle is a performance heuristic independent of the
completion front end (`completion-at-point-functions` are also invoked on
every completion request) and was kept as-is.

## `magik-completion-exemplar-types.el`

Heuristic inference of "what Magik type/exemplar is this variable", used to
know which class's methods to offer after `receiver.`. Entirely buffer-text
based (regex/tree-sitter), plus one read of the session-derived objects
cache.

`magik-completion--try-method-exemplar-type` tries, in order, until one
succeeds:

1. `_self` / `_clone` / `_super` special-casing
   (`magik-completion--self-case`) — resolves via
   `magik-completion--ts-exemplar-of-enclosing-method` /
   `magik-current-method-name` (external, `magik-mode`), falling back to the
   buffer's own filename (a common Magik convention: a method file is named
   after its exemplar).
2. Direct membership in `magik-completion--objects-source-cache` (the
   session-derived cache from `magik-completion-cb-cache.el`) — "is this
   identifier itself the name of a known exemplar".
3. Explicit `_super(ClassName)` form.
4. Typed-literal assignment regexes (`x << 5` → `integer`, `x << "s"` →
   `char16_vector`, `x << {...}` → `simple_vector`, etc. — see
   `magik-completion--typed-assignment-patterns`).
5. `x << SomeClass.new` assignment pattern
   (`magik-completion--class-assignment-patterns`).
6. `@param {Type} param_name` doc-comment lookup near the enclosing
   `_method` keyword (`magik-completion--method-param-type`).

`magik-completion--exemplar-near-point` is the entry point actually consumed
elsewhere (`magik-completion--method-candidates` in
`magik-completion-cb-cache.el`): it finds the receiver identifier immediately
before a `.partial_method_name` at point and resolves its type through the
chain above.

All of this is synchronous, fast (buffer-local regex/tree-sitter, one cache
membership check), and has no notion of "completion" or insertion — directly
reusable, unchanged, from a capf backend.
