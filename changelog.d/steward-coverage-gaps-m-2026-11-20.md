### Added

- **Tests for the runner job paths and submission staging edges.** New suites drive whole jobs through the runner against a scripted server and check what it reports: a seeded job, per-test time limits, a matrix job and its match rows, a missing script, a suite with no scripts and a failed `make` step (both a collection-level build failure), retried and terminal poll errors, and two non-HTTP download failures. Staging tests cover the free-space probe, merges from a missing or linked source, the last Python heuristic, and the `WorkerDaemonError` messages.
