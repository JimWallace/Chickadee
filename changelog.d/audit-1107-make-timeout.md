### Fixed

- **Worker `make` step is now time-bounded (#1107).** The optional pre-test
  `make` ran with a synchronous `waitUntilExit()` on the daemon actor and no
  time limit — and since it runs after the student submission is merged into
  the workspace, a submission with a hung `make` pinned a cooperative-pool
  thread and a job slot forever. `make` now runs through the same bounded
  process machinery as test scripts (timeout + kill + capped output capture +
  allowlisted environment); a hung build maps to `buildStatus: failed` with
  the captured output in `compilerOutput`. Limit is 120s by default,
  configurable via `RUNNER_MAKE_TIMEOUT_SECONDS`.
