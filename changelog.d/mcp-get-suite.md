### Added

- **MCP `get_suite` tool (authoring Phase 3a, read half).** Returns an
  assignment's test-suite structure by public ID — the ordered items
  (hand-written scripts, generated pattern families, notebook checks) with each
  one's tier, points, display name, dependencies, and section, plus the section
  list. `content:read`, course-scoped, read-only (suite editing follows). Reuses
  the author-facing `buildSuitePayload` without raw script bodies.
