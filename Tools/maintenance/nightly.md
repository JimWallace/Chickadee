# The nightly steward

One scheduled task runs every night at 23:30 America/Toronto on the
maintainer's work machine. Its prompt is one line: `Follow
Tools/maintenance/nightly.md`. It replaces the separate maintenance tasks.
The procedure files in this folder (and `Tools/perf-bench/weekly-task.md`)
stay the instructions for each job. This file decides what runs, in which
order, and when to stop.

The goal: use the night's 5-hour usage window, which the maintainer cannot
use, on maintenance. Do as much useful work as fits. Leave every piece of
work in a state that survives the run being cut off.

## Rules

The rules in `Tools/maintenance/README.md` apply to every job. These are
added for the night:

- **Read the root `CLAUDE.md` first.** Load the `steward` skill before you
  drive a pull request.
- **The night has a clock.** Start no new work item after 04:00. At 04:00,
  finish what is running, write the report (below), and stop. The usage
  window can also end early; the next rule makes that safe.
- **Push early.** Open each pull request as a draft as soon as it has its
  first commit, with the `steward` label and a branch named
  `steward/<job>-<YYYY-MM-DD>`. If the run stops, the next night finds the
  work by its label.
- **Merge on green.** Mark a pull request ready and turn on auto-merge
  (squash) when the work is done. GitHub merges it when every required check
  passes. The two exceptions are in `Tools/maintenance/README.md`: a change
  to the "Rules" sections waits for the maintainer, and the performance job
  merges by hand under its own limits.
- **Watch production after each merge.** After a steward pull request
  merges, wait for its deploy (`get_deploy_status`), then call
  `get_health_alerts`. If the deploy rolled back, or a new alert appeared,
  turn off auto-merge on every open steward pull request
  (`gh pr merge N --disable-auto`), merge nothing more tonight, and put it
  first in the report.
- **Work in parallel, but not on everything.** Run each work item in a
  subagent with its own worktree from `origin/main`. Run at most three at
  once. The performance check runs alone (see the calendar).
- **Create the labels once.** If the `steward` or `steward-report` label
  does not exist, create it (`gh label create`).
- **Stay off other people's work.** Push to, merge or close only the pull
  requests that `Tools/maintenance/README.md` allows: those with the
  `steward` label, and the two kinds that a machine opened. Every pull
  request is authored by the maintainer's account, so the label is the
  only sign.
- **No product work.** Do not take issues labelled `enhancement` or
  `discussion`, and do not make a change that needs a design decision. Put
  it in the report instead.

## Order of work

Do the work in this order. Each step that has nothing to do takes one line
in the report.

### 1. Production and `main`

- `get_health_alerts`, `get_deploy_status`: a stuck or failed deploy, or an
  alert.
- The newest `swift-tests.yml` run on `main`: red?
- An open `dependency-update-failed` issue with key `token`: only the
  maintainer can fix it. Put it first in the report.

Fix what a pull request can fix. If production is unhealthy, do not merge
anything tonight; do only work that ends in a draft.

### 2. Last night's pull requests

List open pull requests with the `steward` label. For each: a red check, a
merge conflict or a branch behind `main` is work. Fix it on the same branch.
A draft from a run that was cut off: finish it.

### 3. Tonight's calendar

Each night starts at 23:30 local time: 04:30 UTC the next day in winter,
03:30 UTC in summer. The
calendar uses the CI runs that have finished by then.

| Night of | Job | Procedure |
|---|---|---|
| Sunday | Weekly performance check: first, alone, merges included | `Tools/perf-bench/weekly-task.md` |
| Every night | Fix failed dependency updates | `Tools/maintenance/dependency-failures.md` |
| Every night | Fix failed scheduled checks | `Tools/maintenance/scheduled-checks.md` |
| Sunday | Dead-code review (scan: Sunday 08:00 UTC) | `Tools/maintenance/dead-code-review.md` |
| Monday | Bump behind Swift pins (check: Monday 07:15 UTC) | `Tools/maintenance/swift-pins.md` |
| Tuesday | Triage mutation survivors (sweep: Tuesday 06:00 UTC) | `Tools/maintenance/mutation-survivors.md` |
| Saturday | Audit rotation (one audit a week) | `Tools/maintenance/audit-rotation.md` |

On Sunday night the performance check runs before everything else, step 1
included, and nothing else starts until it ends: its benchmark needs a quiet
machine, and it checks each of its deploys before the next merge, which
another merge would confuse. The Monday digest (15:13 UTC) comes after it.

If a CI run that a job needs has not finished, skip the job for tonight and
say so. Do not start a long CI run and wait for it; the next night takes it.

### 4. Fill work

With the time left before 04:00, take work from these sources, in this
order. One work item is one pull request.

1. **Audit findings.** Open `ui-audit` and `docs-audit` issues: fix the
   findings that have one clear fix. Leave `dead-code` issues alone: their
   removals need test edits, which wait for a live session
   (`audit-rotation.md`, section 3).
2. **Maintenance issues.** Open issues labelled `tech-debt`,
   `maintenance`, `flake-telemetry`, `performance` or `tests`, oldest
   first. Skip one that a comment says a person is handling.
3. **Deeper sweeps.** Run the mutation tool on a tier that the weekly sweep
   does not cover, and answer the survivors. Find coverage gaps in
   `test-coverage.yml`'s newest report and close them with new test files.
   Move npm dependencies that are behind, within their ranges. Leave the
   xeus kernels to `kernel-currency.yml` (`scheduled-checks.md`).
4. **The nightly tests and this steward.** Find what made CI or tonight's
   run slow, flaky or wasteful, and fix it: a slow suite, a flaky test, a
   CI job that does work twice, a step in this file that cost time for
   nothing. A change to the "Rules" sections waits for the maintainer
   (see Rules).

Do not take a fill item that another open pull request already covers.

## The report

Before you stop, file one issue titled `Steward night report (YYYY-MM-DD)`,
with the date the night started, and the label `steward-report`. The
maintainer closes it after reading. It holds:

1. Production: anything wrong, and whether merging stopped.
2. For the maintainer: decisions, secrets, test edits the hook refused, and
   pull requests that wait for review.
3. Merged tonight: each pull request, one line each.
4. Open: each steward pull request and its state.
5. Skipped: each calendar job that did not run, and why.
6. Time: when the run started and stopped, and why it stopped (04:00, out
   of work, or cut off).

Write it in ASD-STE100 English, as the `steward` skill says, and end it
with the Claude Code footer.
