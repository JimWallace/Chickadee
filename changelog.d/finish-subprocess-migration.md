### Changed

- **The test suites' spawn-retry harness moves to `swift-subprocess`, and the
  Foundation `Process` exception list is now accurate.** `runProcessRobustly`
  built a bare `Process` from a factory and retried the *launch* when
  `Process.run()` threw, because under parallel CI load `posix_spawn`
  transiently fails with EAGAIN and Foundation reports it as a misleading
  "file doesn't exist" error. Subprocess does not carry that failure, so the
  retry is gone. `runToolThrottled` keeps the part that was never a Foundation
  defect: `SubprocessThrottle` still holds the suite to four concurrent
  spawns, which is the property `docs/ci-flakiness.md` Family 5 cares about.

  Six call sites follow it, and three helpers that existed only to make
  `Process` safe go with it: `makeCloexecPipe`, `readToEOFBounded` and the
  40-line `awaitBoundedExit` continuation that reaped a child without pinning
  a cooperative-pool thread.

### Fixed

- **The documented list of Foundation `Process` exceptions was wrong.** The
  previous change said three test spawns were deliberately left behind. It
  missed `Sources/APIServer/APIServerApp+Stores.swift`, the local-runner
  autostart, which had no comment saying why it stays — so the codebase
  claimed a completeness it did not have.

  There are now exactly three, listed in one place
  (`Tests/TestSupport/InterpreterSpawn.swift`) and each carrying its reason:
  `PipeCloseOnExecTests` (its subject IS `Pipe` inheritance across a real
  `exec`), `LocalHTTPTestServer` and the autostart (both long-lived children
  held past any single call, which the collected API does not model).
