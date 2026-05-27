### Changed

- **`RunnerCore` is now Embedded-Swift compatible.** Two behaviour-preserving
  tweaks (line-based `from __future__` detection instead of
  `String.contains(_:String)`, and an explicit `Character` split separator) let
  the shared extractor compile under the Embedded Swift wasm SDK — a ~60× smaller
  browser artifact (≈350 KB gzipped vs ≈20 MB) than the standard wasm build.
  No change to native worker output.
