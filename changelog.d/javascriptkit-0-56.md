### Changed

- **JavaScriptKit 0.53.0 → 0.56.1 (wasm bridge).** Brings the upstream
  Embedded-Swift fixes (JavaScriptEventLoop on newer toolchains,
  Embedded-compatible error descriptions); minimum Swift is now 6.3, matching
  the pinned `swift-6.3.2-RELEASE_wasm-embedded` SDK. The manual (non-BridgeJS)
  bridge compiles unchanged. Verified by a full Embedded-SDK rebuild and the
  browser contract suite (141/141, including the output-contract and drift
  tests) against the rebuilt artifact; gzipped wasm grows ~3 KB (0%), within
  budget. The vendored `Public/runner-wasm/` artifact is deliberately untouched
  here — the `runner-wasm-vendor` workflow re-vendors it on main after merge.
