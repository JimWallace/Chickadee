### Changed

- **Tests run each reaper monitor's sweep.** Ten periodic monitors (audit log, diagnostics prune, login attempts, sessions, stale data exports, client diagnostics, activity events, worker nonces, MCP OAuth records and class-goal achievements) now have a test that runs one sweep through the monitor and checks what it removed or wrote.
