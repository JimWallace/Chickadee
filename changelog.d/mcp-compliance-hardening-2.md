### Security

- **MCP compliance hardening, round 2 (UW IRA follow-ups).** Four
  defence-in-depth controls for the MCP server: (1) an optional dedicated
  least-privilege PostgreSQL pool for the MCP path
  (`MCP_DATABASE_USER`/`MCP_DATABASE_PASSWORD` +
  `deploy/sql/mcp-least-privilege-role.sql`) that walls off student tables at
  the database layer, with the content-edit re-grade moved to the privileged
  pool so auto-regrade still works; (2) write tools now **fail closed** when
  their audit record can't be persisted (reads stay best-effort); (3)
  production **refuses to mount** `/mcp` when the Host/Origin DNS-rebinding
  guards are left open, unless `MCP_ALLOW_OPEN_GUARDS=true`; and (4) a
  documented deployment egress allowlist (`deploy/egress-allowlist.md`)
  restricting outbound traffic to the server's real destinations — no model
  API endpoint.
