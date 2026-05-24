### Added

- **MCP `update_suite` tool (authoring Phase 3a, write half).** Edits test-suite
  *script* metadata for an assignment by public ID — tier, points, display name,
  prerequisites (`dependsOn`), and section — through the same `applySuiteEdit`
  path the web editor uses, so raw script bodies are preserved from the zip and
  never sent by the agent. `content:write`, course-scoped; the edit re-runs the
  assignment's validation. Pattern-family / notebook-check metadata and
  reordering are later phases.
