### Fixed

- **Worker env-passthrough tests no longer flake on transient subprocess
  launch failures.** `scriptReceivesEnvVarFromRunner` and
  `scriptEnvVarUnsetWhenNoOverride` now retry only the narrow "subprocess never
  launched" outcome (the `-1` exit sentinel with no output and no timeout — a
  fork/posix_spawn flake under parallel CI load), so the behavioural env-leak
  assertion runs against a real execution. A genuine env-handling regression
  produces output rather than the empty sentinel, so it is never masked.
