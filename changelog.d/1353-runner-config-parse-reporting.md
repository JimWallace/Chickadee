### Fixed

- **An unparseable runner env var is now reported instead of silently falling
  back.** `RunnerDaemonConfig` documented failing fast on a bad value and did
  the opposite, so `RUNNER_MIN_FREE_DISK_MB=2GB` quietly became the 128 MB
  default and the runner kept claiming jobs onto a nearly-full volume — the
  ENOSPC failure that setting exists to prevent. A value that is set but
  unparseable now emits `runner_config_parse_failed` naming the variable, the
  raw text and the default being used.
- **The retry delays are clamped at the boundary.** `RUNNER_RETRY_BASE_DELAY_MS`
  feeds an unchecked `base * 2^attempt` that trapped the runner on its first
  retry for a large enough value, and a negative `RUNNER_RETRY_MAX_DELAY_MS`
  produced a negative sleep, turning the retry loop into a spin against the API
  server.
