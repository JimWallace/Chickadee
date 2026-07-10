### Fixed

- **MCP content edits re-enqueue validation again.** `finalizeContentEdit` now
  passes the acting subject's user id into `scheduleValidationAfterSuiteEdit`;
  previously the helper fell back to the session user, threw 401 inside its
  swallow-all catch on bearer-authenticated MCP requests, and every MCP
  notebook/suite edit silently skipped re-validation (the tool response
  reported the stale `validationStatus`).
- **`get_validation_result` works under the least-privilege MCP role.**
  `deploy/sql/mcp-least-privilege-role.sql` now grants `chickadee_mcp` SELECT
  on the `result_collections` side table (with a validation-only RLS policy)
  — the table #1176 moved the collection blob into, after the grants file was
  written, so every call failed with an opaque `-32603` on deployments using
  the role. Operators must re-run section 4 of that file. A new
  grant-sync test fails the build if a table the MCP read path touches is
  ever missing a grant again.
- **Opaque MCP tool failures are now diagnosable.** Both MCP dispatchers log
  the underlying error before answering a bare `-32603` internal error, and
  `get_validation_result` maps database failures to a structured
  `executionFailed` result so the agent sees the reason.
- **Scheduled assignment opens are hardened (the Lab 6 incident).** A
  `.preview`/`.closed` assignment whose open date has arrived is now also
  published lazily by the dashboard load and the submission gate — the same
  safety-net treatment deadline *closes* have always had — so a stalled
  periodic sweep can no longer leave a lab staff-only past its open time.
  When the sweep refuses to open an overdue-scheduled assignment because
  validation has not passed, it now logs a warning every tick instead of
  skipping silently.
