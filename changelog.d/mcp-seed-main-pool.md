### Security

- **MCP personalization seed bookkeeping moved to the owner pool.** The MCP
  content tools `update_global_inputs`, `update_section_variables`, and
  `preview_personalization` ensure the acting account's own per-assignment seed
  (`assignment_personalization_seeds`) as a side effect. That bookkeeping now
  runs on the main (owner) database pool via `ToolContext.mainDB` / an explicit
  `seedDB` parameter, instead of the least-privilege `.mcp` pool — mirroring the
  MCP audit row and the content-edit re-grade. All real content reads/writes
  stay on the `.mcp` pool, so the student-data wall holds. This removes the need
  for the temporary `GRANT SELECT, INSERT ON assignment_personalization_seeds TO
  chickadee_mcp` stopgap; after deploying, revoke it with `REVOKE SELECT, INSERT
  ON assignment_personalization_seeds FROM chickadee_mcp;` (see
  `deploy/sql/mcp-least-privilege-role.sql`).
