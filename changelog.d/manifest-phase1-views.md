### Changed

- **Manifest model views (manifest v2, phase 1).** `TestSuiteEntry.origin`, `TestProperties.languageDeclaration` and `TestSettings` state the real states of fields that the manifest stores in pairs or in four places. Call sites switch over them. The stored JSON does not change. See `docs/manifest-format-v2.md`.
