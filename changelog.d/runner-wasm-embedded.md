### Added

- **Vendored the Embedded-Swift `RunnerCore` wasm bridge.** The `wasm/`
  sub-package now builds with the Embedded Swift SDK (manual JavaScriptKit
  interop, no Foundation/BridgeJS), and `scripts/build-runner-wasm.sh`
  esbuild-bundles a self-contained, no-CDN browser ESM. Checked in under
  `Public/runner-wasm/` (`runner-core.js` ≈83 KB + `RunnerWasm.wasm` ≈1.1 MB,
  ≈390 KB gzipped total) so CI/contributors need no wasm SDK. Exposes
  `runnerExtractPython(cells, filename)`; wiring it into `browser-runner.js` is
  the next step.
