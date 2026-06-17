### Added

- **Admin diagnostic MCP — browser-error tool (internal).** Adds
  `get_browser_diagnostics` to the read-only admin diagnostic surface
  (`docs/admin-mcp.md`): totals and breakdowns by kind / source / failed
  capability check over a window, plus recent samples carrying the actual
  JupyterLite/Pyodide error message and stack captured by the browser-error
  enrichment. Admin-gated; the response is a hand-built DTO that omits the
  student `user_id` (the no-student-data guarantee, asserted by a per-tool PII
  test) — no dedicated DB role.
