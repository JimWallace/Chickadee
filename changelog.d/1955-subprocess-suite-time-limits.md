### Changed

- **Five suites that start subprocesses now have a time limit (#1955).**
  `SectionInputsTests`, `AuditTockRegressionTests`, `SupportImportTests`,
  `RunnerProfileDetectorTests` and `RunnerExecProbeTests` start `python3` or
  an interpreter probe. They now carry `.timeLimit(.minutes(2))`, so a stall
  fails a named test and does not hold the CI job until its kill.
