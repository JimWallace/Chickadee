### Fixed

- **Bounded daemon shutdown in WorkerDaemonTests (the residual worker-tests
  wedge).** Twelve tests cancelled the daemon task then awaited
  `task.value`/`task.result` unbounded; `Task.value` is not
  cancellation-responsive, so a daemon wedged in a non-cancellable wait rode
  the job to the CI 20-minute kill even though the `.timeLimit` trait had
  already attributed the failure (observed 2026-07-02,
  `workerDaemonContinuesToNextJobAfterProcessingFailure`). A shared
  `awaitCancelledDaemon` helper now polls completion with a 30 s deadline
  and fails the single test instead, still surfacing non-cancellation
  shutdown errors.

### Changed

- **Exec-hang probe forensics (`editor-exec-check.mjs`).** Hang iterations
  now capture the failing-resource URLs behind console errors, every >=400
  response and failed request, and the cell prompt/focus state; green
  iterations report their 4xx/console-error base rate so noise can't
  masquerade as a hang correlate. A second-press discriminator separates a
  new `lostDispatch` class (first Shift+Enter lost to a post-idle focus
  race, kernel healthy — student-facing) from the sustained-busy deadlock
  the probe hunts; only the deadlock class fails the leg.
