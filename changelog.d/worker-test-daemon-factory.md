### Changed

- **Worker tests share one daemon factory.** `Tests/WorkerTests/Support/DaemonTestSupport.swift` now holds the `NoJobPoller` and `NoopReporter` stubs and `makeTestDaemon`, replacing ten private copies across the worker test suites.
