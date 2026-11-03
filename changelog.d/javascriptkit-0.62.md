### Changed

- **The browser runner is rebuilt on JavaScriptKit 0.62.0** (from 0.59.0).
  `wasm/Package.resolved` moves, and the vendored `Public/runner-wasm/`
  artifact is rebuilt in the same change, so the browser runner tests in this
  change exercise the new module rather than the old one. The generated
  `runner-core.d.ts` contract is unchanged. The module is 141,501 bytes
  gzipped, 2,276 bytes over the previous baseline and within budget.
