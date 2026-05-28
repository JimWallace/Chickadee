### Fixed

- **Nightly clean-build canary no longer flakes on connection-pool exhaustion.**
  `test-coverage.yml` ran the entire test suite in one process with code
  coverage but, unlike the per-PR `swift-tests.yml` jobs, never capped Swift
  Testing's parallelism — so at unbounded width the combined connection pool
  timed out, surfacing as spurious test failures and an "Index out of range"
  crash. The nightly now sets `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=4`
  to match the existing per-PR guard. Also fixed the `report-failure` job's
  `gh label create` (missing `--repo`), which silently failed in that
  checkout-less job and broke the failure-tracking issue creation.
