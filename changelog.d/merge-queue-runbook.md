### Fixed

- **The merge-queue runbook names the checks that run in the queue.** It listed eight separate `Swift Tests` jobs, where `swift-tests.yml` says to require only `swift-tests-gate`, and it listed `build-and-verify`, which never ran in the queue. `jupyterlite.yml` now runs on `merge_group` (its guards take under a second), and the runbook says to keep the two browser smoke gates required for pull requests only (#1980).
