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
