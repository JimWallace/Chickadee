### Removed

- **Two pipe helpers the swift-subprocess migration stranded, and the test
  that pinned one of them.** `Core/PipeCloseOnExec.swift` (`setCloseOnExec`,
  `closeOnExecPipe`) reached zero production callers once the zip and notebook
  helpers moved to `Core/ZipSubprocess.swift` and `ScriptExecution` began
  building its own CLOEXEC pipes inline; its only remaining users were its own
  test and one test HTTP server. The worker's `boundedReadToEOF` went the same
  way and had no callers at all. Neither is a behaviour change: the one
  hand-built `Pipe` left in the repository sets the flag itself.

  `PipeCloseOnExecTests` went with the helper. Its subject was Foundation
  `Pipe` inheritance across a real `exec`, so it could not outlive the code it
  measured. `docs/ci-flakiness.md` records what that measurement established
  and that nothing pins it any more.

### Fixed

- **The Foundation `Process` exception list, corrected again.** The previous
  release said exactly three spawns stay on Foundation `Process`. Deleting
  `PipeCloseOnExecTests` leaves two, both long-lived children held past any
  single call — `LocalHTTPTestServer` and the local-runner autostart — which
  is the one shape the collected Subprocess API does not model. A stale
  pointer to the already-deleted `ZipProcessSerialization.swift` is corrected
  at the same time.
