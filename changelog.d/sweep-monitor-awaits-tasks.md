### Fixed

- **Periodic sweeps finish before the database closes at shutdown.** `PeriodicSweepMonitor.stop()` cancelled its loop and returned at once, and it kept no handle on the boot sweep. A sweep that was running at shutdown (fifteen monitors use the type, and every blue-green deploy stops the old colour) kept querying `application.db` while Fluent closed it. `stop()` now cancels both tasks and waits for them, through `shutdownAsync`, and the BrightSpace and LTI grade-push sweeps stop between rows. The monitor is now plainly `Sendable` (#1922).
