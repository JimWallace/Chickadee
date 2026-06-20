### Added

- **Adjustable per-test execution time limit.** The per-test timeout is now
  editable two ways: an assignment-wide default (`TestProperties.timeLimitSeconds`,
  set over MCP with the new `set_time_limit` tool) and a per-test override on a
  hand-written script (`TestSuiteEntry.timeLimitSeconds`, settable via
  `author_script` / `update_suite` `timeLimitSeconds` and readable in
  `get_suite`). The effective limit for a script is
  `entry.timeLimitSeconds ?? manifest.timeLimitSeconds`, resolved in each
  executor (the worker's `NativeScriptExecutor` and the browser runner) rather
  than in the shared wasm `executeSuites` loop, which still receives the
  assignment default as the fallback. Both write paths validate the bound
  (1–600 seconds). Per-family / per-notebook-check / per-case overrides are
  deferred to a later change (TODOs mark the hook points); generated entries
  inherit the assignment default for now. `set_time_limit` is metadata-style
  (like `set_grading_mode`): it changes a grading-environment knob, not what the
  tests check, so it does not re-grade, re-validate, or close the assignment.
