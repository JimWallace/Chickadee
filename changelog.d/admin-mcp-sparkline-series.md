### Added

- **Admin diagnostic MCP: dashboard sparkline series.** The admin MCP
  diagnostic surface can now read the time-series data behind the
  instructor/admin dashboard sparklines, served from the same builders the
  dashboards poll: `get_metrics_card_series` (the five admin operational cards —
  queue depth, jobs processed, load, p95 queue-wait/execution, all windows),
  `get_active_users_series` (the "Active Users" chart), and
  `get_instructor_card_series` (one course's submissions / active students /
  active assignments / browser errors, scoped by `courseCode`). Read-only and
  PII-free: every payload is per-bucket aggregate counts/percentiles only — no
  student identifier reaches the output (the instructor tool's enrolled-student
  lookup is internal scoping, asserted by a per-tool PII test).
