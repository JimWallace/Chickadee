### Added

- **Browser-graded R, on the xeus-r kernel (#1271).** R assignments set to
  `gradingMode: browser` now grade in the student's browser, like Python ones.
  Previously every `.R` test script came back as an error reading "R test
  scripts require WebR" and R could only be graded by the native worker; WebR
  was never a viable route, since `jupyterlite-webr` caps at
  `jupyterlite-core<0.7` and Chickadee pins 0.8.x. The substrate is the same
  vendored `chickadee-r` environment the notebook editor already boots for R
  notebooks, so authoring and grading run one environment with no package skew.
  `RunnerCore` still owns the suite loop, dependency gating, and output
  interpretation for both languages — the kernel supplies only "run this script,
  report its exit code and streams", the seam `ScriptExecutor` exists for.

### Changed

- **The browser runner boots only the runtime an assignment needs.** Test
  scripts are routed to a Python (Pyodide) or R (xeus-r) substrate per script,
  using the classification `RunnerCore` already shares with the native worker, so
  an R lab no longer loads Pyodide and a Python lab never fetches the R
  environment.

### Fixed

- **Per-student personalization reaches R tests graded in the browser.** The
  browser wrote `_ck_inputs.py` for every assignment, so a personalized R test
  saw an empty `chickadee_inputs()`. The seed endpoint now reports the
  assignment's resolved language and the browser writes `_ck_inputs.R` for R
  assignments, matching what the native worker delivers.
