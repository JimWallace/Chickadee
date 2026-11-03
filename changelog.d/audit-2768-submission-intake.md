### Fixed

- **One submission intake for every door.** All seven doors that create a
  student submission now call `SubmissionIntake`. It writes the file, saves
  the row with its attempt number, and runs every effect of the save. The
  `runner-submit` and `browser-failover` doors now record the "accepted" and
  "enqueued" diagnostics, as the upload form always did. The notebook merge
  runs on the thread pool at every door. When the instructor notebook cannot
  be read, the staff-only `POST /api/v1/submissions/file` now merges the
  notebook with itself, as the notebook doors always did, instead of storing
  it unchanged (#2768).
