### Added

- **Manifest v2 reader (manifest v2, phase 3).** The server reads a `schemaVersion: 2` manifest (`ManifestV2`) and still writes only v1. The REST upload accepts version 1 or 2, and bundle import stores an imported v2 manifest as v1. This release must be deployed before any release that writes v2, so that a rollback can always read the stored manifests. See `docs/manifest-format-v2.md`.
