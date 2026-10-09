### Added

- **AI-assisted feedback on written reasoning.** An instructor's own AI agent can draft feedback on the notebook cells a starter tags `reflection`, through three new MCP tools (`list_reflections`, `get_reflections`, `draft_feedback`) under new `feedback:read` and `feedback:write` scopes. The agent sees a random per-assignment handle, never a name, and only the tagged text. The feature is off until a deployment admin turns it on for a course and an instructor turns it on for an assignment, on the web; no MCP tool can turn it on. Course staff review, edit and release every draft on a new feedback page, and the feedback carries no score. Chickadee still calls no model API. See `docs/ai-assisted-feedback.md`.

### Security

- **Gated exception to the MCP student-data wall.** The feedback accessors live in `MCPStudentDataBoundary` and check both gates; `deploy/sql/mcp-least-privilege-role.sql` adds a row-level-security policy that admits a student submission only in a gated assignment, and grants on the new `reflection_feedback` table. Deployments that use the `chickadee_mcp` role must re-run the SQL file. The compliance documents record the change.
