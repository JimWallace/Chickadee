### Fixed

- **A cancelled runner no longer discards a result it already has.** The worker
  fans its job slots out under `withThrowingDiscardingTaskGroup`, so one slot
  throwing a non-retryable error cancels its siblings mid-job — which cancelled
  the result report too, and the grading work was simply dropped. The
  submission then sat `assigned` until `reapStuckAssignedSubmissions` aged it
  out ten minutes later, for a student whose result the runner was holding the
  whole time. The report now runs inside a task cancellation shield
  (Swift 6.4, SE-0504), bounded by the reporter's own network timeouts.

- **The end-of-job heartbeat is awaited instead of abandoned.** It was fired
  into an unstructured `Task` from a `defer`, because a `defer` could not
  `await` before Swift 6.4. That raced `process()` returning: the heartbeat
  could still be in flight while the worker loop claimed the next job. It is
  now awaited in the defer (SE-0493) and shielded, since an async `defer`
  still observes cancellation while the detached `Task` did not.

- **A test's Vapor app is shut down before the test returns.** `AppConfigTests`
  deferred `app.asyncShutdown()` into a detached `Task`, the fire-and-forget
  shape `TestAppTempDirectoryTests` documents as racing test-runner exit and
  sometimes never running at all.

### Changed

- **The server and the runner's remaining Foundation `Process` spawns moved to
  `swift-subprocess`.** `PersonalizationEvaluator` (the server's own
  interpreter spawn, made from the multithreaded Vapor process — the shape
  `Process` deadlocked in, issue #1139), `RunnerProfileDetector` and
  `MimeTypeDetector` now spawn through Subprocess, which owns and drains the
  capture pipes. That retires three hand-rolled ladders that existed only to
  make `Process` safe: close-on-exec pipes with deadline-bounded drains, an
  `isRunning` poll loop, and a terminate/sleep/kill escalation now expressed as
  a `teardownSequence`. The environment allowlist that keeps server secrets out
  of instructor-authored expressions is carried explicitly as
  `.custom` — Subprocess defaults to `.inherit`.

  The zip path (`ZipArchiver` plus the `ZipProcessSerialization` lock and its
  EFAULT retry) is deliberately not included: it is a synchronous public Core
  API with five call sites across the server, so it is its own change.
