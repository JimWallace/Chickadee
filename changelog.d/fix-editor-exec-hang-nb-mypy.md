### Fixed

- **Editor kernel no longer hangs on the first cell (`exec_hang`).** The
  in-browser notebook editor booted to idle and then wedged `[*]`-forever on the
  first cell execute for ~1 in 4 students. Root cause: the bundled **nb_mypy**
  type-checker registered an IPython `pre_run_cell` hook that ran a full,
  synchronous, compiled-WASM `mypy.api.run(...)` before *every* cell on the
  kernel's single thread; the first (cold) run blew past the watchdog, and in the
  race case the background load colliding with the execute could even fatally
  crash Pyodide (`JSON Parse error: Unterminated string`). Reproduced
  deterministically in CI (Chromium + WebKit, both immediate and 45s-settled,
  5/5), which also showed deferring the load does not help — the per-cell mypy run
  itself is the cost. nb_mypy is now **disabled**
  (`scripts/patch-pyodide-kernel.py` injects no activation; the nb_mypy / mypy /
  astor wheels stay vended so re-enabling is a one-line change). In-editor mypy
  type warnings are gone until type-checking is reworked as a non-blocking
  background / language-server check that never runs on the cell-execute path.
