### Fixed

- **Spurious "no runner" when saving an assignment with a healthy runner fleet.**
  The validation pre-check probed runner liveness with a 20 s window against
  `RunnerProfile.lastSeenAt`, but since the 2026-07 poll-write audit that
  column is debounced — an unchanged runner check-in persists freshness at
  most once every 60 s — so for most of each debounce cycle every live runner
  looked stale. A metadata-only save (e.g. editing a due date) would then mark
  the assignment `no-runner` instead of enqueueing validation, and flip every
  live runner profile inactive as a side effect. Both the web Save path and
  MCP content edits shared the race. The pre-check window is now derived from
  the persist debounce (debounce + 60 s = 120 s, matching the diagnostics
  `RUNNER_ACTIVE_WINDOW_SECONDS` default) so persisted-freshness lag can never
  exceed it.
