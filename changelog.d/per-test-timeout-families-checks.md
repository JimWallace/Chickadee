### Added

- **Per-test time-limit overrides for pattern families and notebook checks (MCP).**
  A pattern family can now carry a family-wide `defaultTimeLimitSeconds` (applied
  to every generated case and the auto-existence guard) and each case its own
  `timeLimitSeconds`; a notebook check can carry a check-level `timeLimitSeconds`.
  The resolved value (case override wins over the family default; nil = inherit
  the assignment-wide default) is threaded onto the generated `TestSuiteEntry` so
  the worker and browser graders already honor it. Settable over the MCP content
  API via `create_pattern_family` / `update_pattern_family`
  (`defaultTimeLimitSeconds` + per-case `timeLimitSeconds`) and
  `author_notebook_check` (`timeLimitSeconds`); the range is 1–600 seconds and a
  `0` over MCP clears an override. `get_suite` surfaces the values on each
  family/check spec. The suite-editor UI for these stays deferred.
