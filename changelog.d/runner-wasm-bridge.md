### Added

- **wasm bridge build for `RunnerCore` (`wasm/` sub-package + `scripts/build-runner-wasm.sh`).**
  A separate SwiftPM package compiles the shared, substrate-free `RunnerCore`
  extraction logic to WebAssembly via JavaScriptKit/BridgeJS, exposing
  `extractPythonJSON(cellsJSON, filename)` to JS. Kept out of the main package's
  native build (JavaScriptKit is wasm-only); it depends on the new `RunnerCore`
  library product by path. This is the foundation for the browser runner calling
  the same extractor as the native worker (verified end-to-end in Node). Wiring
  it into `browser-runner.js` and vendoring the bundled artifact is the next step.
