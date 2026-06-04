### Added

- **MCP `delete_suite_item` tool (issue #461).** Removes one item from an
  assignment's test suite — a hand-written `script`, a pattern `familyID` (with
  its generated cases), or a notebook `check` — through the same
  buildSuitePayload / applySuiteEdit path the editor uses, so the manifest is
  rebuilt (the item is no longer graded) and validation re-runs (rejecting a
  removal that would leave a dangling dependsOn). Completes the MCP authoring
  surface (create / edit / delete) needed to migrate hand-written tests to
  declarative families end-to-end.
