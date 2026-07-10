# Session I/O and session-derived caching

This layer is the only part of the package that talks to a live Smallworld
GIS process. It has no dependency on the completion front end, but it is
written with a **blocking/synchronous** assumption worth understanding:
`magik-completion-capf` tolerates a blocking collection function the same way
company's `candidates` command did, so this layer was reused unchanged
during the capf migration — it's just the piece most likely to want an
async rewrite later.

## Files

- `magik-completion-cb.el` — process I/O with the GIS session's `method_finder`
  ("cb" — class browser) subprocess.
- `magik-completion-cb-cache.el` — memoization over `magik-completion-cb.el`.

## `magik-completion-cb.el`

"CB" reuses the class-browser infrastructure from `magik-mode`'s
`magik-cb.el` (a `method_finder` companion process to a running GIS session).

- `magik-completion--cb-get-gis-buffer` — finds *a* live buffer whose name
  starts with `*gis` and has a live process. There is no way to target a
  specific session when multiple are running (see the README's stated
  limitation).
- `magik-completion--magik-session-started?` / `magik-completion--method-finder-started?`
  — confirm a session is up and force-start `method_finder` in it by sending
  literal Magik source via `process-send-string`
  (`"_if method_finder _isnt _unset _then method_finder.lazy_start? _endif $"`),
  then scanning the GIS buffer's text for `"method_finder: loaded"`. Sets
  `magik-completion--session-running`.
- `magik-completion--cb-start-process` — starts (or reuses) the CB subprocess
  via `magik-cb-get-process-create` (from `magik-mode`), only once a session
  is confirmed running.
- `magik-completion--cb-filter` — the process filter for CB output. Buffers
  output until it sees control characters signaling "methods ready" (`\C-e`)
  or "classes ready" (`\C-c`), then reads `magik-cb-temp-file-name` and
  parses it via `magik-completion--cb-candidate-methods` or
  `-cb-candidate-classes`, storing the result in
  `magik-completion--cb-candidadates` (note: typo preserved from the source).
- `magik-completion--cb-candidate-methods` / `-cb-method-args` — parse
  `method_finder`'s textual protocol output into candidate strings, each
  stamped with text properties (`documentation`, `arguments`, `optional`,
  `gather`, `kind`, `iter`, `start-signature`, `end-signature`,
  `assign-signature`) via `magik-completion--cb-add-method-properties`. Capped
  at `magik-completion--cb-max-methods` (1000).
- `magik-completion--cb-candidate-classes` — parses `PACKAGE:CLASS` pairs,
  stamping `kind='exemplar` and `package=<pkg>`.
- **`magik-completion--cb-method-candidates` / `-cb-class-candidates`** — the
  actual entry points used elsewhere. Each sends a scripted sequence of
  `method_finder` commands via `process-send-string`, then **busy-waits**:

  ```elisp
  (while (and (eq magik-completion--cb-candidadates 'unset)
              (magik-cb-is-running ...))
    (sleep-for 0.1))
  ```

  This blocks the calling command (`magik-completion--candidates`, called from
  `magik-completion-capf`) until the async process filter
  (`magik-completion--cb-filter`) populates the rendezvous variable. **This is
  the single biggest "designed for a synchronous caller" assumption in the
  codebase.**
- `magik-completion--exit-cb-buffers` / `-force-kill-cb-completion-buffers` —
  cleanup on session kill; advised onto `magik-session-kill-process`.

External symbols relied on (all from `magik-mode`): `magik-cb-filter-str`,
`magik-cb-in-keyword`, `magik-cb-temp-file-name`, `magik-cb-get-process-create`,
`magik-cb-is-running`, `magik-cb-coding-system`, `magik-session-prompt`,
`magik-smallworld-gis`, `magik-method-name-type`.

## `magik-completion-cb-cache.el`

A thin "fetch once, keep until invalidated" memoization layer — no process
I/O of its own, no company dependency.

- `magik-completion--objects-source-cache`, `-globals-source-cache`,
  `-conditions-source-cache`, `-class-method-source-cache` — flat lists of
  propertized candidate strings (not hash tables/alists — the "cache" is
  literally the last query result).
- `magik-completion--objects-source-cache-loaded` / `-globals-...` /
  `-conditions-...` — booleans gating re-fetch.
- **`magik-completion--int-invalidate-cache`** — resets all of the above to
  nil/unloaded. This is the sole invalidation primitive. It is:
  - advised onto `magik-transmit-region` (`:after`), from `magik-completion.el`,
    so any code sent to the session invalidates the caches;
  - called from `magik-completion--exit-cb-buffers` (session kill) and
    `magik-completion--cb-start-process` (fresh CB process).
  - exposed to the user as the interactive command `magik-completion-invalidate-cache`.
- `magik-completion--load-source-caches` — idempotent "ensure populated";
  called at the top of every `magik-completion--candidates` invocation, but a
  no-op after the first load until invalidated.
- `magik-completion--method-candidates` — class-method lookup with an extra
  memoization trick: it only re-queries CB if the cached short-prefix
  (`"CLASS.<first-char>"`) differs from what's stored; further characters
  typed after that are filtered client-side from the same cached list
  (avoids a session round-trip per keystroke).
- `magik-completion--objects-source-init`, `-globals-source-init`,
  `-conditions-source-init` — populate each cache via the CB entry points
  above (querying `sw:object` descendants, `<global>.` methods, and
  `<condition>.` methods respectively).

## Invalidation triggers (today)

| Trigger | Effect |
| --- | --- |
| `magik-transmit-region` runs (user sends code to the session) | `magik-completion--int-invalidate-cache` — all session caches cleared |
| `magik-session-kill-process` runs | `magik-completion--exit-cb-buffers` — session-running flag cleared, CB buffers/processes killed, caches cleared |
| `magik-session-start-process-post-hook` runs (new session starts) | `magik-completion--kill-cb-ac-buffer` (in `magik-completion-extras.el`) — stale CB buffer/process torn down |

None of this is specific to any particular completion front end; it was
reused unchanged by `magik-completion-capf`. The `sleep-for`-based blocking
fetch was kept as-is during the migration (simplest, preserves current
behavior/UI-freeze characteristics); an async rewrite remains a possible
future improvement, not something this migration attempted.
