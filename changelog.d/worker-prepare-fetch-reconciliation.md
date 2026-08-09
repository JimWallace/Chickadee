### Fixed

- **The runner no longer cancels one prepare-phase artifact download because
  the other failed.** Cancelling an in-flight `URLSession.download` on Linux
  can deadlock — `swift_task_cancel` takes the task's status-record lock and
  then blocks on the session's Dispatch work queue, while that queue is
  completing the same task's transfer and resuming its continuation, which
  wants that lock — and the job setup's `async let` performed exactly that
  cancel whenever the test-setup fetch failed first. The submission download
  and the test-setup acquire now both report a `Result` and are both always
  awaited, so neither leg's failure can cancel the other. Deliberate
  cancellation is unchanged: cancelling the daemon still stops both transfers.
  This was Family 4 in `docs/ci-flakiness.md` — `worker-tests` SIGABRTing at
  the wedge watchdog roughly one CI run in fifteen.
