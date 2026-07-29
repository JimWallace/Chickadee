### Fixed

- **Browser grading now preloads packages imported by bundled helper modules.**
  Pyodide's `loadPackagesFromImports` only scans the single source string it is
  handed and does not follow imports into local modules, so both browser grading
  paths scanned the test script alone. A test script that imported a bundled
  helper which in turn imported `numpy` ran with `numpy` unloaded and failed with
  `ModuleNotFoundError` for every student — while validation passed, because
  validation is graded by the native runner (where `numpy`/`pandas` are installed
  system-wide) even for a `gradingMode: browser` assignment. `browser-runner.js`
  and `grading-worker.js` now scan every `.py` file in the setup once, up front,
  before any script runs. Scanning is per-file so one unparseable source (a
  half-finished student submission) cannot suppress the rest, and remains
  non-fatal so a name Pyodide does not ship never blocks a run.
