# Performance log

One section per week, newest first, written by the weekly performance task
(`Tools/perf-bench/weekly-task.md`) and merged by the maintainer. The plan
behind it is [performance-program.md](performance-program.md); the benchmark
baseline is in [database-performance.md](database-performance.md).

A section has this form:

```text
## Week of YYYY-MM-DD (vX.Y.Z)

### Flagged
- one line per number that moved more than 25%, or a page count that changed;
  "None" when nothing moved

### Production
| Number | Value | Last week |
|---|---|---|
| ... | ... | ... |

### Benchmark (Tools/perf-bench/weekly.sh)
| Page or scenario | Statements | Rows | Time | Baseline |
|---|---|---|---|---|
| ... | ... | ... | ... | ... |

### Top statements by total time
| Calls | Mean ms | Statement (first 80 characters) |
|---|---|---|
| ... | ... | ... |
```

A number that could not be read says `not read:` and the reason.

<!-- New sections go below this line. -->

## Week of 2026-11-22 (v0.6.0-rc.96)

Measured on the same Mac as last week (Apple silicon, Postgres 16 in
Docker). Docker Desktop and the benchmark database were already running.
Production now runs PostgreSQL 18 (upgraded from 16 on 2026-11-22, before
v0.6.0-rc.96), so the benchmark database is two majors behind production.

### Flagged
- None that is real. No page statement or row count went up. Three counts
  went down, from changes merged since last week's run: the instructor
  assignment submissions page is 19 statements and 4,510 rows (#3017,
  already in the baseline note), the admin dashboard reads 354 rows, not
  4,653 (#3132, below), and foreign keys with no leading index fell from
  50 to 49.
- Claim p50 at one assignment, 200 runners was 84 ms (last week 64–76 ms).
  Two re-runs gave 63 and 84 ms, at the same claim rate (194–197/s) and
  server CPU (149–157%) as last week. So this is noise.
- The grades CSV export is 61 ms (last week 83–85 ms on `main`): #3044
  merged on 2026-11-16, and the number matches its measurement.
- Improvement (week 4, views): the instructor submissions roster posted a
  hidden `returnTo` field in each of its ~900 row action forms. Every row
  action already falls back to the roster. #3262 removes the field: page
  974,648 → 905,348 bytes (−7.1%), statements and rows the same, wall time
  62–66 ms (no change within noise). Not merged: see open items.

### Production
| Number | Value | Last week |
|---|---|---|
| Runner poll p50 / p95 / p99 (last 60 min) | 10 / 25 / 25 ms (3,037 requests, peak 51/min) | 10 / 22 / 22 ms (1,260 requests) |
| Status poll p50 / p95 / p99 | no requests since the process started | no requests |
| Queue wait p50 / p95 (24 h) | not read: no jobs in 24 h (Sunday) | not read: no jobs |
| Execution p50 / p95 (24 h) | not read: no jobs in 24 h | not read: no jobs |
| Max queue depth (24 h) | 0 | 0 |
| Peak utilization (24 h) | 0% | 0% |
| Timeouts (24 h) | 0 of 0 jobs | 0 of 0 jobs |
| Runners (id, version, max jobs, active) | Sparrow 0.6.0-rc.96 6/0; Starling 0.6.0-rc.96 6/0; Swift 0.6.0-rc.96 4/0; Chickadee 0.6.0-rc.96 1/0 | Sparrow and Chickadee only (Starling, Swift not polling) |
| Cache hit rate (last 50 jobs) | Sparrow 32%, Starling 24%, Swift 46%, Chickadee 26% (50 samples each) | Sparrow 32%, Chickadee 26% |
| Kernel boot funnel (7 days) | not read: no browser diagnostics in 7 days (total 0) | 30 → 30 → 30 → 21 |
| Health alerts firing | none | `runnerMissing` (Starling, Swift) |
| Free disk | 62.6 GB of 99.1 GB (63%) | 62.5 GB of 99.1 GB (63%) |

The runner poll count per hour is 2.4 times last week's, because all four
runners poll now (17 slots, last week 7).

### Benchmark (Tools/perf-bench/weekly.sh)
| Page or scenario | Statements | Rows | Time | Last week |
|---|---|---|---|---|
| Student dashboard | 22 | 155 | 26 ms | 22 / 155, 28 ms |
| Student submission | 22 | 28 | 21 ms | 22 / 28, 24 ms |
| Student history | 9 | 19 | 10 ms | 9 / 19, 10 ms |
| Status poll | 3 | 3 | 3 ms | 3 / 3, 3 ms |
| Staff view of a submission | 18 | 15 | 15 ms | 18 / 15, 16 ms |
| Instructor assignment submissions (main) | 19 | 4,510 | 64–67 ms, 974,648 bytes | 20 / 4,810, 90 ms |
| Instructor assignment submissions (#3262) | 19 | 4,510 | 62–66 ms, 905,348 bytes | |
| Grades CSV export | 12 | 4,232 | 61 ms | 12 / 4,232, 83–85 ms |
| Instructor assignment list | 14 | 652 | 39 ms | 14 / 652, 44 ms |
| Admin dashboard | 11 | 354 | 22 ms | 11 / 4,653, 35 ms |
| Claims: twelve assignments, 100 runners | 96.2/s | p50 61 ms, p99 211 ms | CPU 111% | 96.0–96.7/s, p50 56–74 ms |
| Claims: one assignment, 50 runners | 47.9/s | p50 25 ms, p99 58 ms | CPU 40% | 47.8–48.2/s, p50 40–41 ms |
| Claims: one assignment, 100 runners | 96.6/s | p50 40 ms, p99 150 ms | CPU 79% | 96.0–97.0/s, p50 49–57 ms |
| Claims: one assignment, 200 runners | 193.2–197.1/s | p50 63–84 ms, p99 265–438 ms | CPU 149–157% | 192.6–195.6/s, p50 64–76 ms |
| Foreign keys with no leading index | 49 | | | 50 |

The admin dashboard reads 354 rows (last week 4,653) with the same 11
statements: #3132 made Postgres count the activity chart's distinct users
per bucket, so the page reads one row per bucket, not one per event.

### Top statements by total time
Since the statistics reset on 2026-11-22 04:02 UTC (about 24.7 h). The
first week this could be read: production loads `pg_stat_statements`
since the PostgreSQL 18 upgrade.

| Calls | Mean ms | Statement (first 80 characters) |
|---|---|---|
| 16,301 | 0.72 | UPDATE "runner_profiles" SET "display_name" = $1, "platform" = $2, "architecture |
| 75,396 | 0.06 | INSERT INTO "worker_nonces" ("nonce_key", "expires_at") VALUES ($1, $2) RETURNIN |
| 24 | 106.55 | SELECT bucket_index, CAST(SUM(a) AS BIGINT) AS total_active, CAST(SUM(m) AS BIGIN |
| 88,770 | 0.03 | SELECT count(*) AS pending FROM ( SELECT $3 FROM submissions WHERE status = $1 OR |
| 75,400 | 0.03 | SELECT "runner_profiles"."id" AS "runner_profiles_id", "runner_profiles"."runner |
| 150,772 | 0.01 | SELECT "id" FROM "submissions" WHERE "status" = $1 ORDER BY "kind" ASC LIMIT $2 |
| 8,876 | 0.13 | INSERT INTO "runner_snapshots" ("id", "runner_id", "recorded_at", "active_jobs", |
| 20,878 | 0.04 | UPDATE "course_enrollments" SET "brightspace_sync_status" = $1, "brightspace_che |
| 11,306 | 0.04 | UPDATE "sweep_leases" SET "holder" = $1, "expires_at" = $2 WHERE "sweep_leases". |
| 295 | 0.89 | SELECT "test_setups"."id" AS "test_setups_id", "test_setups"."manifest" AS "test |

Total database time was 29.9 s in 24.7 h, so no statement here is a load
problem. The first row is 39% of it, and it is more writes than the code
intends: see open items.

### Open items for the maintainer
- **#3262 is not merged.** Every check passed except `visual`, which
  fails on the `admin-alerts` baselines: #3260 added the collation health
  rule (one more row on that page) and did not regenerate them. #3262 does
  not touch that page. Only a person regenerates baselines
  (`Tools/visual-regression/README.md`), so #3262 waits for that. After it
  merges, it still reaches production only by an admin approval: issue
  #3121 (`minor-needed`) is open, so a merge to `main` cuts a pre-release.
- **Runner profile writes.** Production ran 16,301 full-row `UPDATE
  runner_profiles` in 24.7 h for four runners: one per runner about every
  22 s. `RunnerProfileService.lastSeenPersistInterval` intends one per
  60 s. The likely cause: each runner slot holds a poll on the server, the
  slots of one runner re-poll at about the same time, and each one reads
  the aged row and writes every column (both JSON columns included). A
  conditional update of `last_seen_at` alone would make one slot win.
  Taken as steward fill work tonight; see the night report.
- **Benchmark database version.** Production is on PostgreSQL 18; the
  benchmark container is on 16. Move `chickadee-postgres` to 18 so the
  query plans compare.
- **Budgets to lower:** none. `StatementBudgetTests` counts did not change.

## Week of 2026-11-15 (v0.5.951)

Measured on the same Mac as last week (Apple silicon, Postgres 16 in
Docker), so the times compare with last week's section directly.

### Flagged
- None that is real. Every page statement and row count is the same as last
  week, and the foreign-key count is still 50.
- Claim latency moved more than 25% in two scenarios, but did not repeat as
  a code change. Over three runs, twelve assignments at 100 runners gave p50
  72, 74 and 56 ms (last week 54 ms), and one assignment at 100 runners gave
  49, 49 and 57 ms (last week 37–42 ms). Claim rate and server CPU per run
  did not move (96/s at 92–94% of one core; 96/s at 116–119%). No file in
  the claim path, and no package pin, changed between v0.5.930 and v0.5.951.
  So this is machine noise: this run started Docker Desktop cold, and the
  machine load average was about 3.
- Improvement (week 3, APIServer): the grades CSV export spent most of its
  server CPU on hydrating 300 full `APIUser` models (by reflection) and on
  the `Decodable` decode of 3,600 best-grade rows. #3044 reads only the
  three roster columns and decodes the fold rows by column name. Server CPU
  per export 58.4 → 36.4 ms (three runs of 200 requests each, all within
  0.2 ms), wall time 78 → 54 ms. The statements (12) and rows (4,232) do not
  change, and the CSV is byte-identical. **Not merged:** the permission check of this unattended run refused the merge command. Every check is green; it waits for the maintainer.

### Production
| Number | Value | Last week |
|---|---|---|
| Runner poll p50 / p95 / p99 (last 60 min) | 10 / 22 / 22 ms (1,260 requests, peak 21/min) | 10 / 25 / 25 ms |
| Status poll p50 / p95 / p99 | no requests since the process started | no requests |
| Queue wait p50 / p95 (24 h) | not read: no jobs in 24 h (Sunday) | 929 / 6,122 ms |
| Execution p50 / p95 (24 h) | not read: no jobs in 24 h | 356 / 15,989 ms |
| Max queue depth (24 h) | 0 | 6 |
| Peak utilization (24 h) | 0% | 100% |
| Timeouts (24 h) | 0 of 0 jobs | 0 of 299 jobs |
| Runners (id, version, max jobs, active) | Sparrow 0.5.951 6/0; Chickadee 0.5.951 1/0. Starling and Swift not polling (see open items) | four runners on 0.5.930 |
| Cache hit rate (last 50 jobs) | Sparrow 32%, Chickadee 26% (50 samples each) | Sparrow 32%, Starling 24%, Swift 46%, Chickadee 26% |
| Kernel boot funnel (7 days) | boot_start 30 → app_ready 30 → kernel_starting 30 → kernel_idle 21 | 29 → 29 → 29 → 20 |
| Health alerts firing | `runnerMissing` (Starling, Swift) | none |
| Free disk | 62.5 GB of 99.1 GB (63%) | 58.5 GB of 92.3 GB (63%) |

### Benchmark (Tools/perf-bench/weekly.sh)
| Page or scenario | Statements | Rows | Time | Last week |
|---|---|---|---|---|
| Student dashboard | 22 | 155 | 28 ms | 22 / 155, 23–31 ms |
| Student submission | 22 | 28 | 24 ms | 22 / 28, 26–31 ms |
| Student history | 9 | 19 | 10 ms | 9 / 19, 11–14 ms |
| Status poll | 3 | 3 | 3 ms | 3 / 3, 2–5 ms |
| Staff view of a submission | 18 | 15 | 16 ms | 18 / 15, 16–19 ms |
| Instructor assignment submissions | 20 | 4,810 | 90 ms | 20 / 4,810, 79–93 ms |
| Grades CSV export (main) | 12 | 4,232 | 83–85 ms | 12 / 4,232, 81–86 ms |
| Grades CSV export (#3044) | 12 | 4,232 | 53–56 ms | |
| Instructor assignment list | 14 | 652 | 44 ms | 14 / 652, 45–47 ms |
| Admin dashboard | 11 | 4,653 | 35 ms | 11 / 4,653, 36–40 ms |
| Claims: twelve assignments, 100 runners | 96.0–96.7/s | p50 56–74 ms, p99 197–420 ms | CPU 116–119% | 97.4/s, p50 54 ms |
| Claims: one assignment, 50 runners | 47.8–48.2/s | p50 40–41 ms, p99 66–84 ms | CPU 59–60% | 48.2/s, p50 33 ms |
| Claims: one assignment, 100 runners | 96.0–97.0/s | p50 49–57 ms, p99 107–119 ms | CPU 91–94% | 95.6/s, p50 42 ms |
| Claims: one assignment, 200 runners | 192.6–195.6/s | p50 64–76 ms, p99 237–290 ms | CPU 154–159% | 194.3/s, p50 65 ms |
| Foreign keys with no leading index | 50 | | | 50 |

### Top statements by total time
not read: production Postgres does not load `pg_stat_statements`
(`get_query_stats` reports `notPreloaded`).

### Open items for the maintainer
- **Runners:** `Starling` has not polled since 2026-11-15 12:56 UTC.
  `Swift` runs in Docker on this Mac. Docker Desktop was not running, so it
  had not polled since 2026-11-13 23:25 UTC. This run started Docker Desktop
  for the benchmark database, and the `chickadee-runner-swift` container
  started with it. It now polls, but at v0.5.938, so `runnerVersionSkew`
  fires until its update job pulls the new image.
- **#3044 is green and waits for a merge.** This run could not merge it.
  After it deploys, the grades CSV export should use about 38% less server
  CPU. No budget in `StatementBudgetTests` changes.
- **#3017 is still open** (from last week): see last week's open items.
- **Production setting:** load `pg_stat_statements` in the production
  database. It is still not loaded.
- **Watch:** the Chickadee runner (`--max-jobs 1`) averages 14.2 s of queue
  wait over its last 50 jobs, the same as last week. 9 of 30 editor kernel
  boots in 7 days did not reach `kernel_idle` (7 `boot_stalled`).


## Week of 2026-11-13 (v0.5.930 at snapshot; v0.5.932 after this run)

The first section, so there is no last week to compare production with. This
is also the first run on the maintainer's Mac (Apple silicon, Postgres 16 in
Docker), not the 4-vCPU machine of the 2026-11-09 baseline. So this week the
counts are compared with the baseline, and the times with v0.5.876 built and
measured on the same Mac.

### Flagged
- None. Every page count matches v0.5.876 measured on this machine, and so
  do the claim times (one assignment, 100 runners: p50 37 ms on v0.5.876 and
  37–42 ms on main, over three runs). The claim p50 is above the baseline
  table's 24 ms because of the machine, not the code: server CPU per run is
  lower here (96–98% of one core against 142%).
- The baseline table's student submission (23 statements, 29 rows) and staff
  submission (19, 16) are one higher than both versions measure here (22/28
  and 18/15). The cause is how they were measured, not a code change.
- Tooling: `weekly.sh` stopped on macOS because `run-load.sh` read `/proc`.
  Fixed in #3016: merged and live in v0.5.932 at 19:31 UTC, with no health
  alert firing and all four runners online. It touches no server code, so
  no production number moves.
- Improvement (week 2, Core and the database): the instructor submissions
  roster re-read every student's latest submission by id only for its time.
  #3017 takes the time from the ranked summary row: 20 → 19 statements and
  4,810 → 4,510 rows per request, mean wall time about 87 → 71 ms. **Not
  merged**: see the open items.

### Production
| Number | Value | Last week |
|---|---|---|
| Runner poll p50 / p95 / p99 (last 60 min) | 10 / 25 / 25 ms (3,019 requests, peak 51/min) | — |
| Status poll p50 / p95 / p99 | no requests since the process started | — |
| Queue wait p50 / p95 (24 h) | 929 / 6,122 ms | — |
| Execution p50 / p95 (24 h) | 356 / 15,989 ms | — |
| Max queue depth (24 h) | 6 | — |
| Peak utilization (24 h) | 100% | — |
| Timeouts (24 h) | 0 of 299 jobs | — |
| Runners (id, version, max jobs, active) | Sparrow 0.5.930 6/0; Starling 0.5.930 6/0; Swift 0.5.930 4/0; Chickadee 0.5.930 1/0 | — |
| Cache hit rate (last 50 jobs) | Sparrow 32%, Starling 24%, Swift 46%, Chickadee 26% (50 samples each) | — |
| Kernel boot funnel (7 days) | boot_start 29 → app_ready 29 → kernel_starting 29 → kernel_idle 20 | — |
| Health alerts firing | none | — |
| Free disk | 58.5 GB of 92.3 GB (63%) | — |

### Benchmark (Tools/perf-bench/weekly.sh)
| Page or scenario | Statements | Rows | Time | Baseline |
|---|---|---|---|---|
| Student dashboard | 22 | 155 | 23–31 ms | 22 / 155 |
| Student submission | 22 | 28 | 26–31 ms | 23 / 29 |
| Student history | 9 | 19 | 11–14 ms | 9 / 19 |
| Status poll | 3 | 3 | 2–5 ms | 3 / 3 |
| Staff view of a submission | 18 | 15 | 16–19 ms | 19 / 16 |
| Instructor assignment submissions (main) | 20 | 4,810 | 79–93 ms | 20 / 4,810 |
| Instructor assignment submissions (#3017) | 19 | 4,510 | 65–77 ms | 20 / 4,810 |
| Grades CSV export | 12 | 4,232 | 81–86 ms | 12 / 4,232 |
| Instructor assignment list | 14 | 652 | 45–47 ms | 14 / 652 |
| Admin dashboard | 11 | 4,653 | 36–40 ms | 11 / 4,653 |
| Claims: twelve assignments, 100 runners | 97.4/s | p50 54 ms, p99 155 ms | CPU 122% | 100/s, p50 28 ms |
| Claims: one assignment, 50 runners | 48.2/s | p50 33 ms, p99 62 ms | CPU 58% | 50/s, p50 25 ms |
| Claims: one assignment, 100 runners | 95.6/s | p50 42 ms, p99 78 ms | CPU 96% | 100/s, p50 24 ms |
| Claims: one assignment, 200 runners | 194.3/s | p50 65 ms, p99 252 ms | CPU 166% | 162/s, p50 1,270 ms |
| Foreign keys with no leading index | 50 | | | 50 (`ForeignKeyIndexCoverageTests`) |

### Top statements by total time
not read: production Postgres does not load `pg_stat_statements`
(`get_query_stats` reports `notPreloaded`).

### Open items for the maintainer
- **#3017 is open, CI red on `visual` only.** The same 22 pages fail with the
  same diffs as #3014 (UI audit), which merged with `visual` red, so `main`
  no longer matches its own baselines. Regenerating them
  (`Tools/visual-regression/run-visual.sh --update`) needs someone to confirm
  each diff is an intended #3014 change. After that, re-run `visual` on #3017
  and merge it.
- **Test edit:** once #3017 merges, lower the instructor assignment
  submissions budget in `StatementBudgetTests` from 18 to 17. The suite
  prints this itself.
- **Production setting:** load `pg_stat_statements` in the production
  database (`docs/operational-diagnostics.md`), so that this log's top-statements
  table and the week-2 layer can read production.
- **Watch:** the Chickadee runner (`--max-jobs 1`) averages 14.2 s of queue
  wait over its last 50 jobs; the others average 0.8–1.7 s. 9 of 29 editor
  kernel boots in 7 days did not reach `kernel_idle` (7 `boot_stalled`).
- **Local setup:** this run enabled `pg_stat_statements` in the local
  `chickadee-postgres` container (`ALTER SYSTEM` and a restart).
