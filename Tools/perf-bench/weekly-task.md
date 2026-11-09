# The weekly performance task

The steps that the weekly scheduled task follows on the maintainer's work
machine (docs/performance-program.md, "The weekly cycle"). The scheduled
task's prompt only points here, so a change to the procedure is a reviewed
change to this file.

The task has one goal: **leave Chickadee no slower than last week, and fix
what made it slower.** It measures, writes the numbers down, finds the cause
of each issue, fixes it in a pull request, merges that pull request once CI
is green, and checks that the fix reached production and moved the number.

A green merge to `main` deploys to production in 10 to 15 minutes
(CLAUDE.md, "Deployment & CI/CD"). So every merge this task makes is a
production change, and the rules below are what make that safe.

Run on Mondays, before the weekly digest (15:13 UTC).

## Rules

- **Read production; never change it.** Call only the read-only
  `Chickadee_Admin` tools named in step 2, and `get_deploy_status` in step 6. Never run `chickadee-loadtest` or
  anything in this folder against production. A production setting that
  should change (runner `--max-jobs`, a Postgres setting) is a recommendation
  in the log, never an action.
- **Merge only your own green pull requests.** Every change goes in a pull
  request from its own branch, opened by this run. Merge it (squash) only
  when every check on its current head has passed: no failed, cancelled or
  pending check, no merge conflict. Never push to `main`, never force-push,
  never skip, disable or weaken a test to get green, never merge a pull
  request this run did not open.
- **Red CI is work, not a stop.** When a check fails, find the cause and push
  a fix to the same pull request. Re-run a job at most once, and only to show
  that a failure is not this change's (it is red on `main` too). If it is
  still red after three fix attempts, stop on that pull request: leave it
  open, say why in a comment, and list it in the log.
- **One merge at a time.** Merge a fix, wait for the deploy, and check it
  (step 6, item 7) before the next merge, so a bad change is easy to tell apart and to
  revert.
- **A fix that makes production worse is reverted.** If the deployed version
  is unhealthy (`get_health_alerts` fires a new rule, `get_deploy_status`
  reports a rollback) or the number it was meant to fix got worse, open a
  revert pull request at once and merge it when green, then file an issue.
- **Follow the repository's rules.** CLAUDE.md and the area CLAUDE.md files
  apply to every fix: Swift Testing, typed errors, no new environment
  variables, a `changelog.d/` fragment, `scripts/format.sh` before a commit.
- **A fix is small and proven.** It changes only what the regression needs.
  It shows the number before and after. It passes the affected tests, and
  `scripts/format-lint.sh`.
- **Fix every issue you can prove; ask about the rest.** Fix and merge every
  confirmed regression, most important first (status poll, runner claims and
  student pages before staff pages). Four kinds of change are not merged by
  this task: a database migration, a design decision, more than about 200
  changed lines, and a change that `interaction-review` flags on a shared
  object in docs/feature-interactions.md. For those, open the pull request,
  leave it unmerged, and file an issue labelled `performance` with the
  evidence.
- **An existing test file needs the maintainer.** A hook asks before any
  change to an existing file under `Tests/`, and a scheduled run cannot
  answer it. New test files are fine. `StatementBudgetTests` passes when a
  count falls below its budget and prints the new count, so a fix that
  removes statements still goes green; list each budget to lower in the log.
  A fix that cannot go green without editing an existing test is not merged:
  put the exact edit in the pull request body under "Test edit for the
  maintainer" and list it in the log.
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

For each regression, most important first:

1. Branch `perf-fix/YYYY-MM-DD-<short-name>` from `origin/main`.
2. Make the smallest change that restores the number. Prefer the patterns in
   docs/database-performance.md, "Rules": aggregate in SQL, decode through
   SQLKit, add a missing index.
3. Re-measure the page or scenario and record before and after.
4. Run the affected suites (`swift test --filter <Suite>`), including
   `StatementBudgetTests` for any route it covers, then
   `scripts/format-lint.sh`. Run the `diff-reviewer` agent and, for a change
   under `Sources/`, the `interaction-review` agent. Address what they find.
5. Add a `changelog.d/` fragment. Commit, push, and open a pull request
   titled `perf: <what was slow>`. Its body says what regressed, by how much,
   the commit that caused it, the fix, and the numbers before and after.
6. Wait for CI. Fix what fails, as the rules say. When every check is green
   and the change is not one of the four kinds this task does not merge,
   squash-merge it.
7. **Check the deploy.** Wait until `get_deployment_info` reports the new
   version (about 15 minutes; check every few minutes, for up to 45). Then
   read `get_health_alerts` and `get_deploy_status`, and take the production
   number the fix was for again. Record it in the log. If production got
   worse, revert (see the rules). If the deploy did not arrive in 45
   minutes, stop merging, say so in the log, and do not merge the next fix.

A change too large or too risky for this task becomes an issue labelled
`performance` with the same evidence.

### 7. If nothing regressed, improve one thing

When step 4 finds no regression, take this week's layer from the rotation
in docs/performance-program.md ("Layer rotation": week 1 of the month is
RunnerCore and Worker, week 2 Core and the database, week 3 APIServer, week 4
the views and JupyterLite). Find the single largest cost in that layer that
the numbers show, and make one improvement that lowers a measured number,
following step 6, merge included. Record the new number in the table in
docs/database-performance.md, in the same pull request. A lower statement
count goes in the log as a budget to lower in `StatementBudgetTests`.

### 8. Write the log

Add a section at the top of `docs/perf-log.md`, under its intro, in the
format the file describes. Under "Flagged", list each regression with its
cause, the pull request that fixed it, whether it merged, and the production
number after the deploy. List the open items for the maintainer: pull
requests left unmerged and why, test edits, budgets to lower, and the
production settings you recommend changing, with the number behind each.

### 9. Open the log pull request

On `perf-log/YYYY-MM-DD`, update the branch from `origin/main` (the fixes
merged since step 1), then commit only `docs/perf-log.md`. Push, open a pull
request titled `perf-log: week of YYYY-MM-DD` whose body links every fix
pull request and issue from this run, and merge it when green.

### 10. Report

End with a short summary: what was fixed and is live, with the number
before and after; each pull request left open and each issue, with the
reason; and anything that needs the maintainer (a test edit, a budget to
lower, a setting to change, a gap that could not be read).
