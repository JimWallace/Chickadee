### Added

- **MCP `get_validation_result` tool.** An authorized agent can now read the
  per-test outcomes of an assignment's latest validation run (each check's
  status plus `shortResult`/`longResult`, across all tiers), closing the
  diagnosis loop that `validate_assignment` left open — it reported only
  passed/failed/no-runner, so a failing suite couldn't be diagnosed without a
  human copying the per-test grid out of the web UI. The tool is
  `content:read`, course-scoped, and validation-only: it resolves the
  instructor's own reference-solution run from the assignment and never accepts
  or returns a student submission, identity, or grade.
