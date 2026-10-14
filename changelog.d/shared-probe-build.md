### Changed

- **The browser probes build the server once per workflow.** Each of the six
  two-browser probe workflows (`editor-smoke`, `editor-exec-probe`, the three
  notebook probes and `grading-hang-probe`) has a `server` job that builds the
  debug `chickadee-server` and uploads it. The chromium and webkit legs
  download it instead of each compiling it, so a pull request that runs all
  six does 6 server builds, not 12. `editor-smoke-gate` also fails when the
  `server` job fails, because the legs then show as skipped.
