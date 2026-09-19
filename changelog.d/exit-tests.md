### Changed

- **Exit tests prove the watchdog abort and isolate the env-writing tests.**
  `#expect(processExitsWith:)` runs a test body in a child process.
  `WedgeWatchdogAbortTests` uses it to prove what nothing could prove before:
  a silent tracked scope ends the process with SIGABRT and a thread table on
  stderr, and `CHICKADEE_WORKERTESTS_STALL_SECONDS=0` disables the abort. The
  five WorkerTests that write environment variables (`setenv`/`unsetenv`) now
  run their bodies the same way, so a write reaches no other test's
  `environ`; the process-wide env lock those writers needed
  (`Tests/WorkerTests/Support/EnvTestLock.swift`) is deleted with the
  restore-on-exit code. No assertion changed.
