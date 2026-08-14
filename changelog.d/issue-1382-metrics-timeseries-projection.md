### Changed

- **The metrics timeseries and snapshot endpoints stop hydrating full metric
  rows.** `/admin/metrics/timeseries` loaded every `request_metrics` and
  `job_execution_metrics` row in the window as complete models (and sorted
  them for an order-insensitive fold); `/admin/metrics` did the same for its
  job summary. Both now fetch only the two-to-four scalar columns their
  accumulators read. The per-bucket fold itself deliberately stays in Swift:
  SQLite has no percentile aggregate and Postgres `percentile_disc` uses a
  different rank rule than the existing p95, so a SQL fold would change
  reported percentiles per backend. Endpoint values are now pinned exactly
  (p95s included) by the observability tests.
