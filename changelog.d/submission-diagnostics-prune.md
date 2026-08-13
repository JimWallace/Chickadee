### Fixed

- **The observability prune no longer full-scans `submission_diagnostics`,
  and never-finished rows finally age out.** The nightly retention sweep's
  `finished_at < cutoff` ran unindexed against a table that is 1:1 with
  submissions, and rows whose job died before reporting (NULL
  `finished_at`) never matched it — accumulating permanently. The sweep
  column is indexed now, and never-finished rows are aged out on their
  creation time at the same retention window (#1382 item 8).
