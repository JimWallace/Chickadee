### Changed

- **Browser grader: bounded, instrumented worker init.** The in-browser
  submission grader's worker init (loadPyodide + env-config) used to be awaited
  with no timeout — unlike the per-test `run` path — so a wedged boot could hang
  a whole grade forever with no server-side trace. Init is now bounded
  (`GRADING_INIT_TIMEOUT_MS`, default 120 s), terminates-and-retries once on a
  fresh worker, and is bracketed by `grading_init_start` / `grading_init_done` /
  `grading_init_failed` submit-phase breadcrumbs (plus `pyodide_loaded` /
  `env_configured` from inside the worker), so a stalled init is localizable
  instead of invisible. Healthy boots (seconds) are unaffected. Groundwork for
  the JupyterLite 0.8 / Pyodide 314 upgrade, where a second editor-kernel Pyodide
  boots beside the grader under cross-origin isolation; also corrects the stale
  "the submit/validate pages don't carry COOP/COEP" comment in `grading-worker.js`
  (that page has been cross-origin isolated since #574).
