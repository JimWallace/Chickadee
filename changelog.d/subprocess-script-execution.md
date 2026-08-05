### Changed

- **The worker launches scripts through swift-subprocess.** Every subprocess
  the runner starts — sandboxed, unsandboxed, and the optional `make` build
  step — now goes through one `executeScriptLaunch` path on every platform,
  replacing the hand-written `fork()`/`execve()`/`waitpid()` implementation
  that existed only because Foundation's `Process` deadlocked forking from the
  multithreaded daemon (issue #1139). The async-signal-safety burden in the
  forked child, the manual `argv`/`envp` marshalling, the `waitpid` poll loop
  on a detached thread, and the separate macOS `Process` path are all gone.
  Bounded output capture (1 MB per stream, truncation marker) and the explicit
  `ScriptOutput.timedOut` flag are unchanged, so the shared output contract in
  `Tests/Fixtures/output-contract.json` is untouched.

### Fixed

- **A timed-out script's background children are killed on macOS too.** Session
  isolation (`setsid`) and the group-wide SIGTERM → SIGKILL ladder were
  previously Linux-only; the macOS path signalled the direct child alone and
  leaked anything it had backgrounded. Both platforms now run the same
  teardown.
- **A cancelled job no longer leaves its script running.** Cancelling the task
  around a script run tears the process group down; the old Linux path polled
  `waitpid` on a detached thread and never observed cancellation at all.
