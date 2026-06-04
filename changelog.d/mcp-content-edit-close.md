### Changed

- **MCP content edits now close an open assignment.** Editing an assignment's
  suite, pattern family, hand-written script (`author_script`), starter notebook,
  or reference solution through the MCP server now closes a currently-open
  assignment and re-runs validation — matching the web "Save" button — so
  students can't submit against a not-yet-revalidated suite. Each write tool's
  response reports it as `assignmentClosed`; the instructor re-opens with
  `update_assignment(isOpen: true)` once validation passes. The agent-facing
  `initialize` instructions and tool descriptions document the behavior, and now
  also name the `validate_assignment` and `create_assignment` tools.

### Fixed

- **Per-student grading inputs (`_ck_inputs.py`).** The native worker now emits
  the personalization dict keys as escaped Python string literals (matching the
  browser runner's `JSON.stringify` and the script renderer), keeping the three
  materialization paths byte-for-byte consistent.
