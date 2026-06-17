### Added

- **Admin diagnostic MCP — operational tools (internal).** The read-only admin
  diagnostic surface (`docs/admin-mcp.md`) gains two tools: `get_metrics_snapshot`
  (per-runner load/liveness, peak queue depth, recent job status counts,
  queue-wait/execution percentiles, compatibility counters — the same PII-free
  aggregate the admin dashboard serves) and `get_health_alerts` (live evaluation
  of the server-health rules with thresholds). Both enforce admin-only access and
  expose aggregates only — no student, submission, course, or assignment data.
