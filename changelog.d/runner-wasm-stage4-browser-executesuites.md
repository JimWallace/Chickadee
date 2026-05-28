### Changed

- **Browser runner now drives the shared Swift grading loop (Runner WASM
  migration, Stage 4).** `browser-runner.js` no longer contains a hand-written
  copy of the suite-execution loop or output interpretation. It calls
  `runnerExecuteSuites` in the RunnerCore wasm bridge — the SAME
  `executeSuites` + `interpretScriptOutput` the native worker runs — supplying
  only the browser substrate: a callback that executes a script in Pyodide and
  returns raw output (exit code + stdout/stderr). Dependency gating, the
  "Skipped: prerequisite…" message, missing-script handling, and result
  interpretation are now shared, so browser-graded and worker-graded
  submissions produce byte-identical `TestOutcome`s and can no longer drift.
  The async boundary uses JavaScriptEventLoop + `JSPromise`; verified by a
  wasm-backed cross-runner contract test (`output-contract.test.mjs` now drives
  the real wasm against the shared fixture) and an in-browser smoke run.
