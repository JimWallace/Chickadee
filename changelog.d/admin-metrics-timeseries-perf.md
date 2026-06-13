### Fixed

- **`/admin/metrics` and `/admin/metrics/timeseries` no longer stream the full
  `RunnerSnapshot` scan.** The snapshot and time-series endpoints loaded every
  runner heartbeat in the window (a row every ~30s) and bucketed them in Swift —
  the same unbounded-scan / pool-holding pattern that overloaded the diagnostic
  cards. The runner-load aggregation is now done **in the database** on Postgres
  (per-display-bucket utilization average / peak, and the summed-load peak pair),
  with an equivalent Swift aggregation on SQLite (dev / tests) where the data is
  tiny. Both paths produce identical results, pinned by a Postgres-exercised
  parity test. Request- and job-metric series are submission-bound and stay raw.
