### Changed

- **The wasm bridge builds with the root package settings.** `wasm/Package.swift`
  now treats warnings as errors and turns on the same upcoming features as the
  root package. Two settings stay off, because the code that BridgeJS generates
  does not build with them: `InternalImportsByDefault` and strict memory
  safety. The built wasm is byte-identical.
- **`count(where:)` replaces `filter(_:).count` in `Sources/`.** The new form
  does not make a temporary array. A SwiftLint rule (`legacy_filter_count`)
  stops new uses in `Sources/`.
