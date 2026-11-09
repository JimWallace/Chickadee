# The weekly performance task

The steps that the weekly scheduled task follows on the maintainer's work
machine (docs/performance-program.md, "The weekly cycle"). The scheduled
task's prompt only points here, so a change to the procedure is a reviewed
change to this file.

The task has one goal: **leave Chickadee no slower than last week, and fix
what made it slower.** It measures, writes the numbers down, finds the cause
of each regression, and opens a pull request that fixes it. A person reviews
and merges every pull request; the task never merges, deploys or changes
production.

Run on Mondays, before the weekly digest (15:13 UTC).

## Rules

- **Read production; never change it.** Call only the read-only
  `Chickadee_Admin` tools named in step 2. Never run `chickadee-loadtest` or
  anything in this folder against production. A production setting that
  should change (runner `--max-jobs`, a Postgres setting) is a recommendation
  in the log, never an action.
- **Never merge, never push to `main`, never force-push.** Every change goes
  in a draft pull request from its own branch.
- **Follow the repository's rules.** CLAUDE.md and the area CLAUDE.md files
  apply to every fix: Swift Testing, typed errors, no new environment
  variables, a `changelog.d/` fragment, `scripts/format.sh` before a commit.
- **A fix is small and proven.** It changes only what the regression needs.
  It shows the number before and after. It passes the affected tests, and
  `scripts/format-lint.sh`.
- **Larger work is an issue, not a fix.** A fix that needs a migration, a
  change to a shared object in docs/feature-interactions.md that
  `interaction-review` flags, more than about 200 changed lines, or a design
  decision goes in a GitHub issue labelled `performance`, with the evidence.
- **At most two fix pull requests a run.** Rank by student impact (status
  poll, runner claims and student pages before staff pages) and file the
  rest as issues.
- **An existing test file needs the maintainer.** A hook asks before any
  change to an existing file under `Tests/`, and a scheduled run cannot
  answer it. When a fix needs such a change (for example lowering a budget in
  `StatementBudgetTests`), make every other change, put the exact test edit
  in the pull request body under "Test edit for the maintainer", and leave the
  pull request a draft. New test files are fine.
- **A tool that fails is a gap, not a zero.** Write `not read: <reason>` and
  carry on.
- **No user data.** Record counts, times and versions only: no usernames,
  course codes, submission ids, or SQL with literal values.

## Steps

### 1. Start clean

Fetch `main`. Create the branch `perf-log/YYYY-MM-DD` from `origin/main`,
with today's date. Read the newest section of `docs/perf-log.md`: last
week's numbers, and any open item it carried over.

### 2. Production snapshot

| Tool | Keep |
|---|---|
| `get_deployment_info` | the running version |
| `get_metrics_snapshot` | `hotPaths`: p50, p95 and p99 of the runner poll and the status poll; `queueWait` and `execution`: p50 and p95; `maxQueueDepth`; `peakUtilizationPercent`; the `timeout` count in `jobStatusCounts` |
| `list_runners` | for each runner: id, version, max jobs, active jobs |
| `get_runner_detail` (each runner) | `cacheHitRatePercent` and `cacheHitSamples` |
| `get_query_stats` | the ten statements with the most total time: calls and mean time, SQL cut to 80 characters |
| `get_browser_diagnostics` | `kernelBootFunnel`: the count at each phase |
| `get_health_alerts` | the rules that are firing |
| `get_storage_usage` | free disk |

### 3. Benchmark

Run `Tools/perf-bench/weekly.sh` from the repository root, in the background,
and wait for it: it takes about 25 minutes, longer than a foreground command
may run. It needs a local Postgres with `pg_stat_statements` loaded
(docs/database-performance.md, "Re-run the measurements").

If the script itself fails (a changed route, a seed that no longer matches
the schema), that is the first thing to fix: repair the script or the seed in
its own pull request, then run it again.

### 4. Find the regressions

Compare the benchmark with the baseline in `docs/database-performance.md`
(its "The weekly check" section says what counts as a regression), and the
production numbers with last week's section of `docs/perf-log.md`.

- **A count that changed** (statements or rows for a page) is always real.
- **A time that moved more than 25%** is real only if it repeats: re-run that
  one page or scenario (`measure-page.sh`, `run-load.sh`) twice. A time that
  does not repeat is noise; log it and move on.
- **A production number that moved** is compared with what was deployed
  between the two snapshots: `git log` between last week's version tag and
  this week's.

### 5. Find each cause

For each real regression, find the commit that caused it. Read the commits
between last week's version and this week's that touch the route, its
service or its queries. When that does not settle it, bisect: build at each
step and re-measure the one page. Name the commit and the line in the log.

### 6. Fix

For each regression, most important first, up to two:

1. Branch `perf-fix/YYYY-MM-DD-<short-name>` from `origin/main`.
2. Make the smallest change that restores the number. Prefer the patterns in
   docs/database-performance.md, "Rules": aggregate in SQL, decode through
   SQLKit, add a missing index.
3. Re-measure the page or scenario and record before and after.
4. Run the affected suites (`swift test --filter <Suite>`), including
   `StatementBudgetTests` for any route it covers, then
   `scripts/format-lint.sh`. Run the `diff-reviewer` agent and, for a change
   under `Sources/`, the `interaction-review` agent. Address what they find.
5. Add a `changelog.d/` fragment. Commit, push, and open a **draft** pull
   request titled `perf: <what was slow>`. Its body says what regressed, by
   how much, the commit that caused it, the fix, the numbers before and
   after, and any test edit for the maintainer.

Everything beyond two fixes, or too large to fix here, becomes an issue
labelled `performance` with the same evidence.

### 7. If nothing regressed, improve one thing

When step 4 finds no regression, take this week's layer from the rotation
in docs/performance-program.md ("Layer rotation": week 1 of the month is
RunnerCore and Worker, week 2 Core and the database, week 3 APIServer, week 4
the views and JupyterLite). Find the single largest cost in that layer that
the numbers show, and make one improvement that lowers a measured number,
following step 6. Lower the baseline it moves: the budget in
`StatementBudgetTests` (a test edit for the maintainer) or the table in
docs/database-performance.md.

### 8. Write the log

Add a section at the top of `docs/perf-log.md`, under its intro, in the
format the file describes. Under "Flagged", list each regression with its
cause and the pull request or issue that handles it. List the production
settings you recommend changing, with the number behind each.

### 9. Open the log pull request

On `perf-log/YYYY-MM-DD`, commit only `docs/perf-log.md`. Push, and open a
draft pull request titled `perf-log: week of YYYY-MM-DD`. Its body links
every fix pull request and issue from this run.

### 10. Report

End with a short summary: the log pull request, each fix pull request and
issue, and anything that needs the maintainer (a test edit, a setting to
change, a gap that could not be read).
