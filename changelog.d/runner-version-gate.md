### Added

- **Optional minimum-runner-version gate in the manifest.** A test setup's
  manifest may now carry an optional `minimumRunnerVersion`
  (`TestProperties.minimumRunnerVersion`): when set, the server only hands a
  submission to a native runner whose advertised version is at or above it, so a
  suite that depends on a newer runner build is never graded by an older worker.
  It is enforced server-side at job-claim time (a blocked job simply stays queued
  until a new-enough runner polls) and stripped from the runner-facing manifest,
  so existing un-gated assignments are byte-for-byte unchanged. Authorable over
  MCP via the new `set_minimum_runner_version` tool and reported by `get_suite`
  / `get_assignment`. Worker path only — browser-graded assignments have no
  runner version and are never gated.
