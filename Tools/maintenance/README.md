# Scheduled maintenance

CI runs no model (root `CLAUDE.md`, "Subagents and Hooks"), and cloud
scheduled tasks are off for the organization. So every recurring job that
needs judgement runs on the maintainer's work machine, in one Claude Code
scheduled task: the **nightly steward**. It starts at 23:30
America/Toronto, uses the night's 5-hour usage window, and decides what to
do in the order that `nightly.md` sets. Its prompt only points at a file in
the repository, so a change to a procedure is a reviewed change to a file,
not an edit to a prompt that nobody else can see.

| Task | When | Prompt |
|---|---|---|
| Nightly steward | Daily, 23:30 America/Toronto | Follow Tools/maintenance/nightly.md |

The steward runs these jobs on the nights in its calendar
(`nightly.md`, "Tonight's calendar"):

| Job | Procedure |
|---|---|
| Fix failed dependency updates | `dependency-failures.md` |
| Fix failed scheduled checks | `scheduled-checks.md` |
| Bump behind Swift package pins | `swift-pins.md` |
| Triage mutation survivors | `mutation-survivors.md` |
| Dead-code review | `dead-code-review.md` |
| Audit rotation (docs, UI, code that only tests use) | `audit-rotation.md` |
| Weekly performance check | `Tools/perf-bench/weekly-task.md` |

With the time that is left, it takes fill work: audit findings, maintenance
issues, deeper sweeps, and improvements to the nightly tests and to itself.

## Rules every job follows

- Read the root `CLAUDE.md` first and load the `steward` skill before
  driving a pull request.
- Every pull request carries the `steward` label and a branch named
  `steward/<job>-<date>`, unless its procedure names another branch (the
  performance job does). Every pull request is authored by the
  maintainer's account, so the label is how the steward finds its own work.
- A pull request merges by auto-merge (squash) when every required check
  passes, whatever its size, with two exceptions. A change to the "Rules"
  section of this file or of `nightly.md` waits for the maintainer. The
  performance job merges by hand, and its own limits (a migration, a design
  decision, a change over about 200 lines, an `interaction-review` flag)
  override "whatever its size", because it must check each deploy before
  the next merge.
- The steward never merges a red pull request by hand. It pushes to or
  merges only pull requests with the `steward` label, and two kinds that a
  machine opened: a Dependabot pull request named in a
  `dependency-update-failed` issue, and a pull request that a workflow in
  this repository opened and a red check of that workflow names (for
  example the `revendor-kernels.yml` pull request in
  `scheduled-checks.md`). Every merge to `main` deploys to production.
- The maintainer approved this merge policy for the nightly task
  (2026-11-13). The `steward` skill grants no merge rights of its own; the
  policy rests on that approval and on the task's permission settings.
- Never skip, disable or quarantine a test, and never loosen a check, to get
  green. A job gets one re-run at most. No empty commits, and no closing and
  reopening a pull request to kick CI.
- Do not edit an existing file under `Tests/`; the ask-before-test-edit hook
  denies it when no person answers prompts. Add a new test file, or name the
  exact edit in the night report and leave that change for the maintainer.
- One changelog fragment per pull request in `changelog.d/`. Never touch
  `VERSION`, `Sources/Core/ChickadeeVersion.swift` or `CHANGELOG.md`.
- Write pull request bodies, issues and comments in ASD-STE100 English, as
  the `steward` skill says, and end each with the Claude Code footer.
- Each job ends with a short result (found, opened, merged, left for the
  maintainer) that goes into the night report.

## Setting the task up

In the Claude desktop app on the work machine, create one scheduled task:
the schedule and prompt above, the Chickadee checkout as its folder, a fresh
worktree from `main` for each run, the GitHub connector and the
`Chickadee_Admin` connector. Run it once by hand and approve the tools it
asks for, so that unattended runs do not stop on a prompt.

The performance job needs a local Postgres 16 with `pg_stat_statements`
loaded (`docs/database-performance.md`, "Re-run the measurements"), and it
must run on the same machine every week, because its wall times are
compared with a baseline measured there.
