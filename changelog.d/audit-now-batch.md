### Security

- **Worker test scripts no longer inherit the daemon's environment.** Student
  test scripts now run with an allowlisted environment (`PATH`, `HOME`, `LANG`,
  `LC_*`, `TMPDIR`, … plus the per-job `CHICKADEE_*` overrides) instead of the
  worker's full environment, so a submission can no longer read
  `RUNNER_SHARED_SECRET` (or other daemon secrets) back out of its own output
  and forge HMAC-signed worker API requests. Covers sandboxed and unsandboxed
  runners on macOS and Linux.

### Changed

- **"Retest all" now uses a single bulk database UPDATE** instead of one write
  per submission, so re-queueing a deadline-day assignment no longer blocks the
  instructor's request on thousands of sequential saves.
- Added hot-path database indexes the audit found uncovered:
  `request_metrics(finished_at)` (the table had none), `submissions(submitted_at)`,
  `submissions(worker_id, status)`, `client_diagnostics(created_at)`, and
  `assignments(validation_submission_id)`.

### Fixed

- A failed per-student personalization-inputs write on the worker now reports
  the job as `buildStatus: failed` (retestable) instead of silently producing a
  confusing missing-file traceback that was persisted as the student's grade.
- Uploading a file on the new-assignment page no longer throws — the page now
  loads `suite-list.js` alongside `suite-table.js` (the file classifier it
  calls), and an unrelated use-before-declaration bug in the upload-merge helper
  is fixed.

### Removed

- Deleted the pre-v0.4.79 `resolveEditSuiteFiles` suite-rebuild chain and the
  superseded in-browser Pyodide grading engine in `notebook.js` (both dead;
  grading runs through the shared RunnerCore path).
