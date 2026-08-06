### Added

- **Browser grading for Lua, on a vendored xeus-lua kernel.** A `.lua` test
  script now grades in the browser the way a `.py` or `.R` one does:
  `RoutingExecutor` sends it to `/lua-grading-worker.js`, which boots the new
  `chickadee-lua` environment (~19 MB, against 74 MB for R and 85 MB for
  Python) and reports an exit code, stdout and stderr back to the same
  RunnerCore suite loop the other two use. `Tools/runner-support/test_runtime.lua`
  ships the `passed()` / `failed()` / `errored()` API, the per-student seed and
  inputs, and submission loading; the native worker injects it alongside the
  Python and R helpers, so one file serves `lua script.lua` and the kernel
  alike. Proven on a real kernel by
  `node Tools/browser-grading-smoke/smoke.mjs --language lua`, now a leg of the
  browser-grading smoke workflow.

  This is the architecture test `docs/adding-a-xeus-kernel.md` recommends
  rather than a language a course can be authored in — Lua has no literal
  renderer, no pattern families, no notebook checks and no personalization
  driver, and `AssignmentLanguage` is still `.python | .r`. What it does have
  is a measured answer to the question the document asks: the browser substrate
  really is language-agnostic, and R's two hard-won lessons (the `evaluate`
  stderr trap and the one-top-level-expression rule) turned out to be xeus-r
  properties that do not generalise.
