### Changed

- **Sweep tests no longer poll on a wall clock.** `PeriodicSweepMonitor.sweepOnce` runs one leased tick and returns when it ends. Eleven sweep tests await it instead of starting the loop and polling every 25 ms for up to 10 seconds.
