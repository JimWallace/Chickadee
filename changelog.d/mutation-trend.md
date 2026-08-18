### Added

- **The mutation sweep now produces a trend, not just a snapshot.** Each weekly
  run merges its ten shards into a committed `MutationReports/<date>.json` and
  `Tools/mutation/trend.py` prints the series — one row per run, plus the
  survivors present in every comparable run, which is the standing backlog.
  Previously the sweep's entire output was perishable (expiring artifacts and a
  prose issue body), so there was no way to ask whether the suite was improving.
  The trend refuses three comparisons that would read as good news without
  being it: a partial sweep whose smaller survivor count is missing coverage
  rather than progress, a configuration change that makes the next number a
  different measurement in the same units, and a moved line — survivors are
  keyed by source text, not line number, so an unrelated edit above one no
  longer reports the hole as fixed. Still a report, never a gate, and still no
  threshold anywhere. See [docs/mutation-trend.md](docs/mutation-trend.md).
