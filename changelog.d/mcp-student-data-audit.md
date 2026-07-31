### Added

- **MCP student-data access audit (2026-07).** New compliance document
  `docs/compliance/mcp-student-data-audit-2026-07.md`: a full re-audit of both
  MCP surfaces (content-authoring, 51 tools; admin diagnostics, 19 tools —
  the latter's first compliance pass) answering "no student data, direct or
  inferred" ahead of the privacy-team submission. Re-verifies every prior
  P0/P1 remediation against current code, inventories the admin tools'
  per-tool PII posture, and records nine findings — the material ones being
  free-text importers (warning+ log messages carrying student identifiers
  into `query_logs`; the BrightSpace sync-error detail embedding the pushed
  grade) with concrete remediations. Documentation only; no behaviour change.
