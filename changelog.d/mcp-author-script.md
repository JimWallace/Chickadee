### Added

- **MCP `author_script` tool.** The content-authoring MCP server can now create
  or replace a single hand-written test or support file in an assignment's test
  setup. A test tier (`public`/`release`/`secret`/`student`) upserts the file
  and its suite entry — with `points`/`displayName`/`dependsOn`/`sectionID` — and
  re-runs validation; the `support` pseudo-tier writes a non-graded helper file
  (e.g. a per-assignment data generator) that test scripts and personalization
  expressions can import. Generated pattern-family / notebook-check scripts stay
  read-only (edit the family/check instead). This closes the gap that previously
  forced raw-script edits through the web editor, and unlocks seed-aware secret
  tests for per-student personalized answers.
