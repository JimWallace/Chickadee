### Fixed

- **`client_diagnostics` is now pruned like every other diagnostics table.** It
  takes a row per browser error, kernel boot failure and grading failover, each
  carrying a message and a full JS stack, from what is the highest-volume
  endpoint the server serves — and nothing ever deleted them. Every neighbouring
  table (`job_execution_metrics`, `runner_snapshots`, `request_metrics`,
  `submission_diagnostics`) already went through the 24-hour observability
  prune; `client_diagnostics` now does too, on the same retention window, using
  the index already present on `created_at`.
- **Indexed the session reaper's sweep column.** The hourly reaper runs
  `DELETE FROM _fluent_sessions WHERE created_at < cutoff`, but the migration
  that added `created_at` added no index — so once an hour the reaper scanned
  and locked the table with the highest read volume in the schema. Added
  `idx_fluent_sessions_created_at`.
