### Added

- **Assignment versioning and recovery — design doc.** `docs/assignment-versioning.md`
  specifies immutable per-edit content snapshots (manifest + zip + starter
  notebook) with content-addressed per-file blobs, a linear append-only history
  that is never deleted, and three MCP tools (`list_assignment_versions`,
  `get_assignment_version`, `restore_assignment_version`). Planning only — no
  behaviour change.
