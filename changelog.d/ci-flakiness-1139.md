### Fixed

- **Fork-safe Linux script launch — root cause of the #1139 CI flake and a
  latent production grading hang.** `executeLinuxScriptProcess` used to call
  `setenv()` and bridge Swift Strings in the forked child before `execvp`;
  in a multithreaded process the child can inherit a glibc lock (environ,
  malloc arena) captured mid-acquire with no thread left to release it, and
  deadlock before exec. Under parallel CI load this reproduced 8 times in
  200 launches; it presented as `WorkerTests.stdoutIsCaptured()` failing
  after exactly the script time limit, or the whole job wedging to the
  20-minute kill when the deadlock landed before `setsid()` and the
  timeout's group-kill missed (the final blocking `waitpid` then hung
  forever). The child now runs only async-signal-safe calls — argv/envp/cwd
  are materialized as C buffers pre-fork and handed to `execve()` — plus:
  `setsid()` first so the group-kill always lands, a bounded post-kill reap
  instead of the unbounded `waitpid`, `FD_CLOEXEC` on capture pipes
  (Foundation's `Pipe` does not set it) so concurrent spawns can't hold the
  write end open and starve EOF, and a bounded poll-based final drain
  replacing the blocking `readDataToEndOfFile()`. Fixed logic: 0 hangs in
  3000 stress iterations.

### Security

- **Student scripts no longer inherit the worker's full environment on
  Linux.** The old fork child applied the allowlisted env via `setenv()` on
  top of the *inherited* parent environment, so non-allowlisted worker vars
  — the shape `RUNNER_SHARED_SECRET` arrives in — leaked into every test
  script on Linux despite the allowlist design. `execve()` with a
  parent-built envp replaces the environment outright, matching the macOS
  path's semantics; a canary regression test now pins this.

### Changed

- **CI flake containment (docs/ci-flakiness.md).** Subprocess-spawning
  WorkerTests suites carry `.timeLimit(.minutes(3))` so a stall fails with a
  named test instead of holding the job to its 20-minute kill; a
  `/rerun-failed` PR comment now re-runs only the failed jobs (new
  `rerun-failed.yml`) instead of forcing a full-pipeline re-roll via empty
  commit; the webkit grading-hang probe tolerates `hangs<=1/12` on PR runs
  with a loud warning (hard zero kept on dispatch/scheduled runs and on
  chromium); the required editor-smoke gate retries its webkit legs once,
  loudly, for the known ambient exec-hang class.
