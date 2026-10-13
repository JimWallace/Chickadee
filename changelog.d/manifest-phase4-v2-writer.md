### Changed

- **Manifests are stored in the v2 form (manifest v2, phase 4).** `encodeManifest` stores a manifest as `schemaVersion: 2` when that form holds it exactly, and as v1 otherwise. Every path that sends a manifest out of the server still sends v1: the runner job, the browser runner's manifest endpoint, the MCP manifest resource and course-bundle export. After this release is deployed, do not roll back to a release before the phase 3 release, which is the first that reads v2. See `docs/manifest-format-v2.md`.
