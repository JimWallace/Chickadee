### Fixed

- **A C++ or Java submission that throws during a `stdoutEquality` test now
  reports its real failure.** Both runtimes install a stdout capture that was
  only undone on the success path, so an exception unwound past the restore and
  the verdict was written into the capture instead of to the runner. C++ students
  saw a bare "failed" with no reason; Java students saw an `error` blaming a
  `System.exit` they never called. `ck::CaptureStdout` now restores in its
  destructor and `ck.passed`/`failed`/`errored` restore before printing, so a
  verdict always reaches the runner.
