### Changed

- **Nightly clean-build canary hardened against connection-pool-pressure flakes.**
  `test-coverage.yml` runs every target in one process under code coverage —
  the most pool-pressured run in CI — and was intermittently reddening on
  transient AsyncKit "Connection request timed out" failures rather than real
  breaks. The Swift Testing parallelism cap is now tightened to width 2 (from
  4, half the concurrent test-app DB pools) and the test step is retried once:
  a lone flake no longer reddens the canary or auto-files a tracking issue,
  while a genuine break fails both attempts and still reports failure. A flaky
  first attempt is surfaced as a CI `::warning::` so flakiness stays visible.
