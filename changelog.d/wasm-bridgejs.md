### Changed

- **The browser grading wasm's bridge is BridgeJS.** The hand-marshalled
  bridge — five `JSClosure`s reading untyped `JSObject` properties with
  `?? ""` / `?? 0` defaults and writing results property by property — is
  replaced by `@JS` structs and functions in `wasm/Sources/RunnerWasm/Bridge.swift`,
  compiled by the BridgeJS plugin, which builds under the Swift 6.4 Embedded
  SDK. The generated TypeScript declaration is vendored as
  `Public/runner-wasm/runner-core.d.ts` and is the contract. The legacy
  `globalThis.runner*` entry points are a small JS adapter over the typed
  exports (`wasm/loader/runner-core-entry.js`, now the loader's esbuild entry),
  carrying the old bridge's tolerances — Jupyter's `cell_type`, omitted suite
  fields, and a rejecting `run` callback becoming an exit-2 error outcome — so
  browser-runner.js and every existing test kept their contract unchanged.
  Cost, measured: +9 KB raw / +4 KB gzip on the wasm and +6 KB gzip on the
  loader for BridgeJS's struct codecs, against 190 lines of marshalling Swift
  removed. `runner-core-exports.test.mjs` pins the typed surface.
