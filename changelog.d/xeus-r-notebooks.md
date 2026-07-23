### Added

- **In-browser R notebooks (xeus-r).** The JupyterLite editor now runs an R
  kernel (xeus-r, R 4.5.1) alongside Pyodide Python — an uploaded R notebook
  opens with the vendored xeus-r kernel and grades as R end to end. The kernel
  is a manually-vendored WebAssembly artifact (CI has no emscripten-forge
  access), so CI verifies the committed bundle (`check-xeus-vendored.sh`) rather
  than rebuilding it. R-on-Safari (SharedArrayBuffer isolation) and blank-R
  notebook creation from the UI are follow-ons; xeus-python stays on Pyodide.
  See `docs/xeus-r-kernel-spike.md`. (#77)
