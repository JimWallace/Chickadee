### Added

- **Admin diagnostic MCP: dashboard + operational-surface tools.** The admin MCP
  diagnostic surface gained eleven read-only tools so an agent has parity with
  the admin/instructor web dashboards' operational views, each served from the
  same builder its page uses. Dashboard sparklines: `get_metrics_card_series`
  (the five operational cards), `get_active_users_series` (the "Active Users"
  chart), `get_instructor_card_series` (one course's submission / active-student
  / active-assignment / browser-error counts, scoped by `courseCode`). Operational
  surface: `get_metrics_timeseries` (flexible window/bucket incl. HTTP request
  latency), `get_queue_state` (pending/in-flight/oldest-pending/stuck counts),
  `list_runners` + `get_runner_detail` (capability profile + aggregate per-stage
  timing + cache-hit rate), `get_storage_usage` (disk footprint by component +
  per-assignment), `get_request_metrics` (slowest routes / status classes),
  `list_connected_agents` (MCP OAuth grants), `get_brightspace_sync_status`
  (grade-push health), and `query_audit_log` (activity counts by action/category).
  All read-only and PII-free by construction: aggregates/percentiles, redacted
  DTOs, or counts-only — no student identity, grade, submission content, or
  enrollment is reachable. The three identity/grade-adjacent sources (audit log,
  BrightSpace sync, per-job runner metrics) drop the student fields entirely
  (`query_audit_log` returns no actor/IP/metadata; `get_brightspace_sync_status`
  drops username + grade; `get_runner_detail` omits the per-job rows the web page
  shows), each asserted by a per-tool PII test.
