### Changed

- **Python browser grading moved from Pyodide to the xeus-python kernel
  (#1271).** Test scripts now execute on the same `chickadee-python` environment
  the notebook editor runs, so authoring and grading are one environment for
  Python as they already were for R — "it ran in the editor" now implies "it
  grades in the browser". No configuration: there is one Python substrate.
- **`scipy`, `sympy`, `scikit-learn`, `statsmodels` and `pillow` are now in the
  editor/grading environment.** Pyodide resolved these at run time from its
  package index; a fixed environment has no runtime escape hatch, so they are
  baked in. They are now available while *authoring* too, which Pyodide-only
  grading never allowed. A browser probe asserts each one actually imports in a
  real kernel, not merely that it is present in the vendored bytes.
  `networkx`, `seaborn` and `plotly` have no emscripten-forge build and remain
  unavailable.

### Removed

- **The main-thread grading fallback.** It existed only because Pyodide can run
  on the main thread, and it carried a real hazard: a synchronous CPU-bound loop
  in student code never yields, so the per-test timer never fires and the tab
  freezes with the submission lost. Every substrate is now a Web Worker, where
  `Worker.terminate()` actually kills a runaway. A browser without Worker support
  fails the grade over to the native worker.
- **`Public/grading-worker.js` and the Pyodide package preloader.** A fixed
  environment needs no import scanning, which retires the class of bug where a
  bundled helper's imports were invisible to the scanner.
