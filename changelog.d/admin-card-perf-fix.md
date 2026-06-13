### Fixed

- **Admin diagnostic-card sparklines no longer exhaust the database connection
  pool.** The `GET /admin/metrics/cards` endpoint scans up to 30 days of
  `RunnerSnapshot` / `JobExecutionMetric` rows; under the dashboard's 60s poll,
  concurrent requests stacked that long-running query on separate connections
  and could drain the Fluent pool, surfacing as `ConnectionPoolTimeoutError`
  and 500s on unrelated pages. The series is now served from a single-flight,
  short-TTL cache (`MetricsCardCache`) so the heavy scan runs at most once per
  minute regardless of caller count, and the two 30-day queries project only
  the columns the sparklines need.
