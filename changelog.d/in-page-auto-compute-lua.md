### Added

- **Lua assignments compute expected values in the browser.** Auto-compute runs
  on the vendored xeus-lua kernel — the same one that grades a browser-graded
  Lua submission — instead of round-tripping to the server. Octave is now the
  last kernel language still on the server driver; C++ and Racket have no kernel
  to run and stay there by construction.

  Two Lua facts shape the implementation, and neither is R's:

  Every kernel cell is its own chunk, so the `local function` declarations in
  the seeded runtime do not survive it. The runtime now ends by re-binding its
  serializer and JSON encoder as globals, in the same chunk that declares them —
  the only place they are still in scope. Without it every snippet fails on a
  nil call, reported as a per-cell error rather than as the substrate failure it
  is.

  Each snippet is one *call* expression, matching the grading wrapper, because
  xeus-lua first tries to compile a cell as `return <cell>` and mis-reads a cell
  that opens with a `local` declaration. R's snippets are one expression for an
  unrelated reason (its ~180ms inter-expression yield), which Lua does not have.

- **Arguments are rendered one `local` per argument, never into a table.** A
  JSON null is `nil` at top level and the `chickadee.NULL` sentinel inside a
  table, because a table constructor does not store `nil` at all; building an
  argument table would silently drop the slot and call the solution with the
  wrong arity. The sentinel is seeded from the same Swift expression
  `test_runtime.lua` binds, since the eval worker loads no `test_runtime`.

- **The Lua snippets are executed under a real interpreter in CI**
  (`Tests/BrowserRunnerJSTests/lua-eval-execution.test.mjs`), with each snippet
  `load`ed as its own chunk so a helper that only works by sharing a file scope
  fails. It runs the runtime the server actually seeds, extracted from the Swift
  constants that define it. A browser-grading smoke row covers the kernel half.

### Changed

- **The browser-grading smoke's auto-compute probe is one parameterized page**
  rather than one per language, and the Swift-constant extraction it depends on
  moved to `Tools/browser-grading-smoke/auto-compute-runtime.mjs`, shared with
  the Node execution suite.

### Fixed

- **The browser-grading smoke's path filter named languages by hand and had
  already gone stale** — it listed r/python/lua grading and python/r eval while
  the matrix also ran octave grading, so an octave-only change skipped the job
  that tests it. It is now a pattern, which also fails in the safe direction: an
  unrecognised language matches and runs the smoke rather than skipping it.
