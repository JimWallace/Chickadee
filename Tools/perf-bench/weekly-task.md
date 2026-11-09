# The weekly performance task

The steps that the weekly scheduled task follows, on the maintainer's work
machine (docs/performance-program.md, "The weekly cycle"). The scheduled
task's own prompt only points here, so a change to the procedure is a reviewed
change to this file, not an edit to the task.

Run on Mondays, before the weekly digest (15:13 UTC).

## Rules

- **Read production; never change it.** Call only the read-only tools of the
  `Chickadee_Admin` MCP that are named below. Never run `chickadee-loadtest`
  or anything in this folder against production.
- **One pull request a week, and only to `docs/perf-log.md`.** Do not change
  code, baselines or any other file. A regression is reported, not fixed.
- **A tool that fails is a gap, not a zero.** Write `not read: <reason>` in its
  row and carry on.
- **No user data.** Record counts, times and versions only: no usernames,
  course codes, submission ids or SQL with literal values.

## Steps

1. **Start clean.** In the repository, fetch `main` and create a branch named
   `perf-log/YYYY-MM-DD` from `origin/main`, using today's date.

2. **Production snapshot.** Call these tools and keep the numbers listed:

   | Tool | Keep |
   |---|---|
   | `get_deployment_info` | the running version |
   | `get_metrics_snapshot` | `hotPaths`: p50, p95 and p99 of the runner poll and the status poll; `queueWait` and `execution`: p50 and p95; `maxQueueDepth`; `peakUtilizationPercent`; the `timeout` count in `jobStatusCounts` |
   | `list_runners` | for each runner: its id, version, max jobs and active jobs |
   | `get_runner_detail` (each runner) | `cacheHitRatePercent` and `cacheHitSamples` |
   | `get_query_stats` | the ten statements with the most total time: calls and mean time, with the SQL text cut to its first 80 characters |
   | `get_browser_diagnostics` | `kernelBootFunnel`: the count at each phase |
   | `get_health_alerts` | the rules that are firing |
   | `get_storage_usage` | free disk |

3. **Benchmark.** Run `Tools/perf-bench/weekly.sh` from the repository root,
   in the background, and wait for it to finish: it takes about 25 minutes,
   longer than a foreground command may run. It needs a local Postgres with
   `pg_stat_statements` loaded (docs/database-performance.md, "Re-run the
   measurements"). If it fails, keep the last 40 lines of its output for the
   log and skip to step 5.

4. **Compare.** Compare the benchmark summary with the baseline tables in
   `docs/database-performance.md`, using the regression rules in its "The
   weekly check" section. Compare the production numbers with the previous
   section of `docs/perf-log.md`. Flag any number that moved more than 25%,
   and any page whose statement or row count changed at all.

5. **Write the log.** Add a new section at the top of `docs/perf-log.md`, under
   its intro, in the format that the file describes.

6. **Open the pull request.** Commit only `docs/perf-log.md`, with the title
   `perf-log: week of YYYY-MM-DD`. Push the branch and open a draft pull
   request with that title. Its body lists the flagged numbers, or says that
   none moved. Do not merge it.

7. **Report.** End with one line: the pull request link and the number of
   flagged numbers.
