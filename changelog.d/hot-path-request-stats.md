### Added

- **In-memory counts for the hot-path routes.** The idle runner poll, the runner heartbeat and the submission status poll do not persist a `request_metrics` row on success, so they had no count and no latency. The server now counts every request on these routes in memory, with a fixed-bucket latency histogram since the process started and per minute over the last 60 minutes. `/admin/metrics` and the admin MCP tool `get_metrics_snapshot` report it as `hotPaths`. See `docs/operational-diagnostics.md` §"Hot-path counts".
