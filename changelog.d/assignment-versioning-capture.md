### Added

- **Assignment versioning — content edits are now captured (slice 2).** Every
  assignment content edit, whether made in the browser or through an MCP write
  tool, records an immutable version: the pre-edit state is seeded as a baseline
  the first time a setup is touched, and the post-edit state is snapshotted once
  the request succeeds. Capture hangs off the write seams both surfaces already
  use (`loadAssignmentAndSetupForWrite` and
  `authorizedAssignmentAndSetupForWrite`), so a tool or route is versioned
  without wiring anything, and edits that changed nothing write no row. History
  is not yet readable or restorable — those are the next slices.
