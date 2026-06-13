### Fixed

- **Admin diagnostic-card sparklines no longer overload the database.** The
  `GET /admin/metrics/cards` endpoint scanned up to 30 days of `RunnerSnapshot`
  rows (recorded every ~30s, so tens of thousands of rows); under the
  dashboard's 60s poll, concurrent requests stacked that long query on separate
  connections and could drain the Fluent pool, surfacing as
  `ConnectionPoolTimeoutError` and 500s on unrelated pages. Two changes fix it:
  (1) on Postgres the runner-load series is now pre-aggregated **in the
  database** to per-5-minute summed load, collapsing the scan to a few hundred
  rows (SQLite keeps an equivalent Swift aggregation); and (2) the whole series
  is served through a single-flight, 60s-TTL cache (`MetricsCardCache`) so the
  query runs at most once a minute no matter how many pollers or pages request
  it. The "Max Load" card's peak pair is computed at 5-minute resolution.
