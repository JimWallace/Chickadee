### Changed

- **Each periodic sweep runs once at boot, not twice.** `PeriodicSweepMonitor` no longer fires a detached boot sweep beside its loop, whose first iteration already sweeps at once. Thirteen services ran their first sweep twice under one lease on every start. The `runImmediately` flag is gone (#2054, audit A16).
