### Fixed

- **Intermittent HTTP 500 when storing a browser-graded submission.** SQLite runs
  in WAL mode but without a `busy_timeout`, so a contended write fails
  immediately with `SQLITE_BUSY`; the `MAX(attempt_number)` read-then-insert in
  `saveSubmissionWithNextAttemptNumber` could additionally hit
  `SQLITE_BUSY_SNAPSHOT` when another connection (a Fluent session write, a
  background monitor) committed between its read and its write. That surfaced as
  an intermittent 500 on `POST /api/v1/submissions/browser-result` — the grade
  computed fine in the browser, but ~1 submission in ~12 failed to store. The
  submission insert and the result save now retry on transient SQLite lock errors
  (re-running the transaction against a fresh snapshot, which a `busy_timeout`
  alone can't fix). Postgres serializes via its advisory lock and is unaffected.
  `run-smoke.sh` now also dumps the server log tail on a check failure so a
  server-side 500 is diagnosable in CI.
