### Added

- **MCP student-data access audit (2026-07) + UW approval readiness plan.**
  New compliance documents `docs/compliance/mcp-student-data-audit-2026-07.md`
  and `uw-ai-approval-readiness.md`: a full re-audit of both MCP surfaces
  (content-authoring, 51 tools; admin diagnostics, 19 tools — the latter's
  first compliance pass) answering "no student data, direct or inferred" ahead
  of the privacy-team submission, plus a step-by-step map onto UW IST's
  AI-tool approval pathway. Companion inventories
  (`tool-inventory` / `data-flow` / `policy46` / `trust-boundary`) refreshed
  with 2026-07 addenda covering the current 70-tool census.

### Security

- **Audit findings F-1–F-4, F-6 remediated.** Warning+ log messages no longer
  interpolate student identifiers (usernames, user ids, submission ids,
  client IPs move to metadata the admin `query_logs` ring buffer redacts at
  capture; `RingBufferLogHandler.piiKeys` extended; new
  `LogMessageHygieneTests` source-scan guard). BrightSpace sync-error text is
  sanitized at write: the rejection detail no longer embeds the pushed grade,
  `BrightSpaceSyncError` descriptions omit the orgDefinedId and truncate D2L
  bodies (new `BrightSpaceDetailSanitizationTests`). `get_request_metrics`
  matches its `pathPrefix` against normalized routes, closing a
  concrete-id existence probe. `get_browser_diagnostics` samples carry the
  coarse browser/OS label instead of the raw User-Agent. The MCP student-data
  wall test now also scans `Transport/` + `Resources/` and confines identity
  models to the authorization allowlist.
