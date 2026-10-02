### Changed

- **One helper runs a bounded child process.** The worker's MIME detector and capability probes and the server's personalization evaluator each raced a subprocess against a timer by hand, with a private outcome type and exit-code conversion. They now call `runBounded` in Core, and `TerminationStatus.shellExitCode` is the one conversion (the zip helper uses it too). Behaviour does not change; new tests pin output, exit codes, the deadline, the process-group teardown, the environment and the output cap (#1792).
