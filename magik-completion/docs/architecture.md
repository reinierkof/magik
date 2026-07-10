# magik-completion architecture overview

`magik-completion` provides a `completion-at-point-function` (capf) for Magik
source buffers (`magik-ts-mode`) and Magik session/REPL buffers
(`magik-session-mode`), both provided by the sibling `magik-mode` package. It
supplies method/variable/global/condition/slot/exemplar/snippet completion,
driven partly by static analysis of the current buffer (via tree-sitter) and
partly by live introspection of a running Smallworld GIS session through its
`method_finder` ("class browser" / "cb") subprocess.

It has no dependency on `company` — any capf-consuming front end (the
default in-buffer completion UI, [Corfu](https://github.com/minad/corfu), or
company-mode itself via its own built-in `company-capf` backend) can drive
it. See [capf-migration-plan.md](capf-migration-plan.md) for the design
decisions behind this and what was previously a company-mode-only backend.

See also:

- [capf-protocol.md](capf-protocol.md) — the capf contract: dispatch, prefix
  detection, annotations, kind, post-completion insertion.
- [session-and-cache.md](session-and-cache.md) — how data is fetched from the
  live Magik session and cached/invalidated.
- [buffer-analysis.md](buffer-analysis.md) — tree-sitter-based parsing of the
  current buffer for in-scope variables, parameters, slots, and type
  inference.
- [snippets.md](snippets.md) — yasnippet integration for parameter
  placeholders and snippet-as-candidate completion.

## Module map

- **`magik-completion.el`** — Minor mode + the `magik-completion-capf` function
  (bounds/prefix, candidates, `:annotation-function`, `:company-kind`,
  `:exit-function`); aggregates candidates from all sources. This *is* the
  capf protocol implementation.
- **`magik-completion-prefixes.el`** — Determines the prefix string at point and
  which "context" (method call, slot access, global, condition, dynamic,
  object) point is in. Pure buffer/regex/syntax logic, no dependency on the
  completion front end.
- **`magik-completion-annotation.el`** — Builds the annotation string shown next
  to a candidate (params, iterator marker, snippet marker, package name).
  Pure function of a candidate string's text properties; used directly as
  `magik-completion-capf`'s `:annotation-function`.
- **`magik-completion-cb.el`** — Talks to the running GIS session's
  `method_finder` subprocess: sends Magik source, parses its textual protocol
  output into candidate lists with text-property metadata. Written as
  **blocking**: busy-waits (`sleep-for 0.1`) until an async process filter
  delivers results — capf tolerates this the same way company did, at the
  cost of a brief UI pause on first completion after a `.`.
- **`magik-completion-cb-cache.el`** — Memoizes the results of
  `magik-completion-cb.el` queries (objects, globals, conditions,
  class-methods); invalidated on `magik-transmit-region` / session kill.
- **`magik-completion-buffer-cache.el`** — Buffer-local caches of parameters,
  variables, slots, and the enclosing exemplar/class name, refreshed once
  per line-change.
- **`magik-completion-exemplar-types.el`** — Infers the Magik "type"/exemplar of
  a variable at point (`_self`, `_super`, typed-literal assignment,
  `ClassName.new` assignment, `@param {Type}` doc comments).
- **`magik-completion-treesitter-extras.el`** — Tree-sitter queries: enclosing
  scope (method/block/procedure), variables in scope (`<<` assignment,
  `_import`, loop vars, `_local`), parameters, and locating a class's
  `def_slotted_exemplar` node.
- **`magik-completion-yasnippet-handling.el`** — Looks up yasnippet templates
  for candidates, builds parameter-placeholder snippets, and inserts them
  after a candidate is accepted, via `magik-completion-capf`'s
  `:exit-function`, which runs after the completion UI has already inserted
  the candidate text into the buffer.
- **`magik-completion-extras.el`** — Class-browser buffer/process cleanup on
  session restart. (Previously also registered Magik candidate "kinds" into
  `company-vscode-icons-mapping` for company-box icon rendering; that was
  dropped when the `company` dependency was removed — see
  [capf-migration-plan.md](capf-migration-plan.md). Per-kind icons are still
  obtainable via `:company-kind`, e.g. with Corfu's `kind-icon` package.)

## Data flow (single completion attempt)

1. Emacs calls `magik-completion-capf` (via `completion-at-point-functions`).
   - It calls `magik-completion--prefix`, which checks whether point is in a
     comment/string, or (in a session buffer) outside the "typeable" area
     after the prompt. If so, all context flags are cleared and `nil` is
     returned — no completion starts here.
   - Otherwise it calls each `magik-completion--at-*-prefix` predicate from
     `magik-completion-prefixes.el` and stores the results in the global flags
     `magik-completion-prefix-at-methods`, `-at-conditions`, `-at-dynamics`,
     `-at-globals`, `-at-slot`, `-at-objects`, then calls
     `magik-completion--determine-cur-prefix`, which scans backward from point
     to the start of the current identifier and stores the (downcased)
     substring in `magik-completion-cur-prefix`, returning it.
   - **Implicit contract**: this mutates seven global variables as a side
     channel that the `magik-completion--candidates` call (next) reads. Safe
     because both calls happen sequentially within the same
     `magik-completion-capf` invocation.
   - `magik-completion-capf` derives `start` as `(- (point) (length prefix))`
     and `end` as `(point)`.
2. `magik-completion-capf` calls `magik-completion--candidates`.
   - It first calls `magik-completion--load-source-caches` (ensures the
     session-derived caches — objects/globals/conditions/methods — are
     populated; see [session-and-cache.md](session-and-cache.md)).
   - It then conditionally appends candidates from each source, gated by the
     context flags set in step 1: buffer-local candidates
     (slots/params/variables/exemplar name, only in `magik-ts-mode`),
     globals/dynamics, objects (plus yasnippets treated as objects), class
     methods, conditions.
   - Every candidate list is run through `magik-completion--filter-candidates`,
     which keeps only strings matching the current prefix and not already
     present (cross-source de-duplication).
   - Each survivor gets a `yasnippet` text property if a snippet with that
     key exists, then the whole list is filtered against
     `magik-completion-blacklisted-candidates`.
3. As the user narrows the prefix by typing more characters, Emacs re-invokes
   `magik-completion-capf` on each keystroke, but `magik-completion-cb-cache.el`'s
   memoization means only the *first* character after a `.` typically
   triggers a live session round-trip — further characters are filtered
   client-side from the same cached list.
4. The completion UI calls `magik-completion--annotation` (`:annotation-function`)
   and `magik-completion--kind` (`:company-kind`) per candidate shown in the
   popup, both pure functions of text properties already attached to the
   candidate string.
5. When the user accepts a candidate, the completion UI inserts its text into
   the buffer, then calls `magik-completion--post-completion`
   (`:exit-function`), which expands a yasnippet for the method's parameters
   (or for the snippet body, if the candidate itself was a yasnippet key).

## The two independent caching layers

There are two unrelated caches, invalidated by different triggers:

- **Session-derived cache** (`magik-completion-cb-cache.el`): objects, globals,
  conditions, class-methods. Invalidated by `magik-completion-invalidate-cache`
  (bound to `magik-transmit-region` via advice, and to session-kill via
  `magik-completion--exit-cb-buffers`). Getting this data requires a live round
  trip to the GIS process the first time, or after invalidation.
- **Buffer-derived cache** (`magik-completion-buffer-cache.el`): parameters,
  variables, slots, enclosing classname. Recomputed once per line change
  (cheap heuristic: `line-number-at-pos` changed since last check), purely
  from tree-sitter parsing of the current buffer — no process I/O.

## Known limitations (from the README, confirmed in code)

- Bound to a single GIS session: `magik-completion--cb-get-gis-buffer` picks
  "a" buffer whose name starts with `*gis` with a live process — there is no
  way to target a specific session when several are running.
- Type inference for `_self`/variables is heuristic (regex/tree-sitter based),
  not a real Magik type system — soft typing means it can't always determine
  an exemplar.
- Candidate documentation popup (`:company-doc-buffer`) shows the method's
  `documentation` text property, when present, via `magik-completion--doc-buffer`.
  Only method candidates carry this property today; buffer-local
  (params/slots/variables) and class/exemplar candidates have none, so they
  show no popup.
