### Added

- **Time-limit editing in the web UI (#979).** The assignment edit page's Test
  Suite header gains an editable "Default time limit" field, saved live via a
  new `PUT /instructor/:assignmentID/time-limit` endpoint — the web twin of the
  `set_time_limit` MCP tool (no close, no re-validation, no retest). The Test
  Editor modal gains a per-script "Time limit" field (blank inherits the
  assignment default) riding the existing `timeLimitSeconds` suite DTO field.

### Fixed

- **Web suite edits no longer wipe per-test time-limit overrides.** The suite
  editor dropped `timeLimitSeconds` when round-tripping rows, so any reorder or
  points/tier edit in the browser silently erased overrides set via the
  `author_script` / `update_suite` MCP tools. The field now rides the same
  carry-and-re-emit contract as `hint`.
