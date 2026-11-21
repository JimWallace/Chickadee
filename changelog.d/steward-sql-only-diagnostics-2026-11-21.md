### Removed

- **Non-SQL fallbacks in diagnostics and admin reads.** The Swift fallbacks for a database without SQL are gone from the request timing series, the pending queue depth, the runner job counts, the admin assignment counts, the runner last-seen read, the user activity chart and the retention submission counts. The server runs on Postgres only, so these paths ran only in tests. They now throw `AppError.internalFailure`.
