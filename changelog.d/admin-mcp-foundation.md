### Added

- **Admin diagnostic MCP — foundation (internal).** The dispatch-layer scaffold
  for a separate, read-only, admin-only MCP surface for operational diagnosis
  (`docs/admin-mcp.md`): `AdminMCPMode` / `DiagnosticScope` / `AdminMCPConfig`
  (`ADMIN_MCP_MODE`, off by default), `AdminToolContext` with an admin-only gate,
  a parallel `DiagnosticTool` registry + `AdminMCPDispatcher` (tools-only,
  read-only), and the first tool `get_deployment_info`. Nothing is mounted yet —
  this slice has no runtime effect; the HTTP transport, bearer auth, and OAuth
  consent land in following slices.
