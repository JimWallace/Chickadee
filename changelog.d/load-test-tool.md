### Added

- **Load-test tool for the hot paths.** `chickadee-loadtest` simulates deadline traffic: runner slots that poll `POST /api/v1/worker/request` and result views that poll `GET /api/v1/submissions/:id`. It reports the request rate, the status counts and the p50 / p95 / p99 latency of each stream. It refuses a host that is not on this machine unless `--allow-remote` is given. See `docs/load-testing.md`.
