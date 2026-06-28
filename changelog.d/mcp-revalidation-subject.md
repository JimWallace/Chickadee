### Fixed

- **MCP content edits now actually re-run validation (and refresh
  `solution.py`).** Every MCP authoring write (`author_script`,
  `create_pattern_family`, `author_notebook_check`, suite/section edits, …)
  funnels through `finalizeContentEdit`, which calls
  `scheduleValidationAfterSuiteEdit` to re-kick validation — but that helper
  enqueued the validation submission without an acting user, so on the MCP
  bearer path (no session `APIUser`) the enqueue threw `401 Unauthorized`. The
  helper swallows enqueue errors, so the failure was invisible: agent edits
  silently skipped re-validation, and the server-side `shared/{setupID}/solution.py`
  the personalization evaluator imports was never refreshed after an edit (only
  `update_solution`, which already threads the subject, regenerated it).
  `finalizeContentEdit` now resolves the acting subject and threads it through
  `scheduleValidationAfterSuiteEdit` → `enqueueRunnerValidationSubmission`, so an
  agent edit re-validates exactly like the web Save button. Web callers are
  unchanged (they pass nil and resolve the session user from `req.auth`).
