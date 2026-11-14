# Database performance at course scale

This page records what a profiling pass measured on 2026-11-09, the rules
that came out of it, and the baseline that the weekly check compares against.
`Tools/perf-bench/` re-runs every measurement here.

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
| Grades CSV export | 2.6 s, of which 49 ms is the database | 44,000 rows hydrated as Fluent models | Fixed (`bestGradePercentByStudentAndSetup`): one SQL fold. 157–195 ms, of which 30 ms is the database |
| Instructor assignment submissions page | about 300 ms, of which 31 ms is the database | 5,100 rows hydrated | Improved: grade summaries and timestamps decode as plain rows (SQLKit), and the other reads take only the columns shown. 167–191 ms |
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

## The baseline

Measured on v0.5.876 (2026-11-09) with `Tools/perf-bench/weekly.sh` on the
4-vCPU machine described above. Times are warm.

**Pages.** Statements, database time and rows are per request.

| Page | Statements | Database ms | Rows | Wall time |
|---|---|---|---|---|
| Student dashboard `/` | 22 | 1.9 | 155 | 43–63 ms |
| Student submission | 23 | 1.4 | 29 | 34–48 ms |
| Student history | 9 | 0.4 | 19 | 19–23 ms |
| Status poll `GET /api/v1/submissions/:id` | 3 | 0.07 | 3 | 4–11 ms |
| Staff view of a submission | 19 | 0.6 | 16 | 27–33 ms |
| Instructor assignment submissions | 19 | 36 | 4,510 | 167–191 ms |
| Grades CSV export | 12 | 30 | 4,232 | 157–195 ms |
| Instructor assignment list | 14 | 29 | 652 | 93–109 ms |
| Admin dashboard | 11 | 11 | 4,653 | 60–77 ms |

On 2026-11-13 the instructor assignment submissions page dropped from 20
statements and 4,810 rows to 19 and 4,510: the per-student summary returns
the latest submission's time, so the page no longer re-reads those rows by
id. Its times above are still the 2026-11-09 ones.

**Runner claims.** There is a backlog of 20,000 pending jobs. Each runner polls
every second for 30 s.

| Scenario | Claims per second | p50 | p99 | Server CPU |
|---|---|---|---|---|
| One assignment, 50 runners | 50 | 25 ms | 48 ms | 71% |
| One assignment, 100 runners | 100 | 24 ms | 52 ms | 142% |
| One assignment, 200 runners | 162 | 1,270 ms | 1,349 ms | 240% |
| Twelve assignments, 100 runners | 100 | 28 ms | 408 ms | 159% |

At 200 runners the machine saturates: it also runs Postgres and the load
client. The claim rate there is the number to watch, not the latency.

## Re-run the measurements

`Tools/perf-bench/` needs:

- a local Postgres with `pg_stat_statements` in `shared_preload_libraries`;
- release builds of `chickadee-server` and `chickadee-loadtest`.

`weekly.sh` makes both builds. It writes everything to `$PERF_WORK`
(`/tmp/chickadee-perf` by default), outside the repository. The server reads
only the variables that it reads in production.

- `setup.sh` drops and rebuilds the benchmark database (`chickadee_perf`):
  - The server migrates it.
  - An admin and an instructor are created through `/register`, and course
    STAT231 through `/admin/courses`.
  - `sql/seed.sql` adds the data set.
  - It saves the page ids and a signed-in cookie jar per role.
- `measure-all.sh` measures each page in the table above. It writes one file
  per page to `$PERF_WORK/out/pages/`.
- `bench.sh PREFIX` runs the four claim scenarios. It writes one file per
  scenario to `$PERF_WORK/out/load/`.
- `weekly.sh` runs all of these and prints one summary.

To run the whole check:

```sh
Tools/perf-bench/weekly.sh
```

It takes about 25 minutes, and most of that is the release build.

## The weekly check

Once a week, run `weekly.sh` on the current `main` and compare its summary
with the baseline above. Use the same machine as the last run, because the
numbers depend on the hardware. A regression is any of these:

- **A page reads more.** Its statements or its rows per request go up. These
  counts do not depend on the machine, so a rise is a real change. Find the
  change that caused it.
- **A page is slower.** Its wall time goes up by more than 25% over the
  baseline.
- **Claims are slower.** The claim rate at 200 runners falls by more than
  10%, or the p50 at 100 runners goes up by more than 25%.
- **A foreign key has no index.** The count of foreign keys with no leading
  index differs from the list in `ForeignKeyIndexCoverageTests`.

When the numbers change for a known reason, such as an intended change to a
page, update the baseline tables here in the same PR as the change.
