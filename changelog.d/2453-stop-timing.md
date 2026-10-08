### Fixed

- **A local HTTP server test no longer times `stop()` against the wall clock.** The one-second bound could not catch a `stop()` that waited for the server, and could fail when a loaded runner paused the test. The test still proves that each server stops and that its siblings keep serving. (#2453)
