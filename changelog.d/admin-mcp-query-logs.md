### Added

- **Admin diagnostic MCP — query_logs (internal).** Completes the read-only
  admin diagnostic surface (`docs/admin-mcp.md`) with `query_logs`: recent
  server log events (warning and above) filterable by level, message substring,
  and look-back window. Backed by a shared in-process `AdminEventSink` ring
  buffer fed by a `RingBufferLogHandler` multiplexed alongside Vapor's existing
  console logger — console output is unchanged, PII metadata keys are dropped at
  capture, and the buffer is per-process and resets on restart. Admin-gated; no
  database and no new configuration.
