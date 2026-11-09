# Database performance at course scale

This page records what a profiling pass measured on 2026-11-09, and the rules
that came out of it. Re-measure before you trust a number here for a later
version.

## How it was measured

- A release build of the server ran on one 4-vCPU machine, together with
  Postgres 16 (default settings) and `chickadee-loadtest` (`docs/load-testing.md`).
- The data was one course with 300 students and 12 assignments, about 18,000
  submissions (about 1,500 per assignment) and 25,000 results.
- The log tables held 150,000 to 400,000 rows each: `request_metrics`,
  `user_activity_events`, `audit_log` and `runner_snapshots`.
- `pg_stat_statements` counted the statements of each request.
  `EXPLAIN (ANALYZE, BUFFERS)` gave the plans, and `perf` sampled the server
  CPU.

The machine was shared, so the points where it saturated are low. The ratio
of server CPU to database time is what carries over to production.

## What it found

| Path | Cost at this scale | Cause | State |
|---|---|---|---|
| Delete of a submission | 34 ms per row; one assignment (about 1,500 submissions) about 50 s | `request_metrics.submission_id` had no index | Fixed (`CreateForeignKeyIndexes`): 3.5 ms per row |
| Runner claim with 20,000 pending jobs | 28–63 statements and 18–31 ms of server CPU per claim; p50 1.6–2.7 s at 200 runners | 50 full candidate rows per poll, Fluent query building, lost lock races | Improved: one-statement claim, a 10-row first page, one setup query per group. 100 runners on one assignment: p50 50 → 26 ms, CPU 210% → 135%; on twelve: p50 1.4 s → 0.57 s. Still saturates the 4-vCPU test machine at 200 runners |
| Grades CSV export | 2.6 s, of which 49 ms is the database | 44,000 rows hydrated as Fluent models | Fixed (`bestGradePercentByStudentAndSetup`): one SQL fold, about 25 ms |
| Instructor assignment submissions page | about 300 ms, of which 31 ms is the database | 5,100 rows hydrated | Fixed: grade summaries and timestamps decode as plain rows (SQLKit), and the other reads take only the columns shown. Not re-measured |
| A student's submission page | 16% of its CPU | the avatar-wardrobe unlock check (`WardrobeUnlockStore.grantNew`) re-reads the student's whole grade history on each view | Fixed (`WardrobeGrantChecks`): the history is read only when a result or an assignment's due date or concept has changed |
| Student dashboard | 33–47 ms | | Fine |
| Status poll (`GET /api/v1/submissions/:id`) | 3 statements, 5–10 ms | | Fine |
| Idle runner poll | 3 statements, 2.4 ms of CPU | | Fine |

## Rules

- **Index a foreign key whose referenced rows are deleted in bulk.** Postgres
  does not index the referencing side. Without an index, each delete of a
  referenced row scans the referencing table. Submissions, setups and
  assignments are deleted many at a time, so their keys need an index. A user
  or a course is deleted one at a time, and on a table that takes a row per
  request or per job, the index entry on each insert costs more than one scan
  per delete. `ForeignKeyIndexCoverageTests` fails on a new foreign key with
  no index that leads with its column, unless the key is on that test's list.
  Use a partial index (`WHERE col IS NOT NULL`) when most rows leave the
  column empty. A partial index adds no entry for a row where the column is
  NULL.
- **A new index locks writes to its table while it builds.** Migrations run in
  a transaction, so they use a plain `CREATE INDEX`, not `CONCURRENTLY`.
  During a deploy, the old color's writes to that table wait for the build.
  On a table of a few hundred thousand rows this is about a second.
- **Fluent hydration costs about 40–60 µs per row, and it runs on the event
  loop.** A request that hydrates 40,000 rows holds that loop for seconds and
  delays every other request on it. For a read that grows with the term,
  aggregate in SQL, or decode through SQLKit into a plain `Decodable` struct.
- **Count and group in SQL, not in Swift.** A count that loads rows to count
  them grows with the table, not with the answer.
