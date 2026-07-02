### Changed

- **`BrightSpaceGradeSyncService.swift` split along its seams (#1116).** The
  1050-line file is now grade selection (pure, separately testable), grade
  clears, and the sweep — with the sweep's 5–7-parameter free-function
  threading replaced by a `GradeSyncSweep` struct holding the invariant
  dependencies. The hand-rolled 60s monitor is replaced by the shared
  `PeriodicSweepMonitor` (matching its two sibling sweeps), and the two
  batch loaders no longer duplicate the chunked-IN loading. No behavior
  change.
