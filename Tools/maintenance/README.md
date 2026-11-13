# Scheduled maintenance tasks

CI runs no model (root `CLAUDE.md`, "Subagents and Hooks"), and cloud
scheduled tasks are off for the organization. So every recurring job that
needs judgement runs as a Claude Code scheduled task on the maintainer's
work machine. Each task's prompt only points at a file in the repository, so
a change to a procedure is a reviewed change to that file, not an edit to a
prompt that nobody else can see.

| Task | When | Prompt | Merges |
|---|---|---|---|
| Fix failed dependency updates | Daily, 05:23 America/Toronto | Follow Tools/maintenance/dependency-failures.md | Auto-merge on green |
| Bump behind Swift package pins | Monday, 03:37 America/Toronto | Follow Tools/maintenance/swift-pins.md | Auto-merge on green |
| Triage mutation survivors | Wednesday, 04:41 America/Toronto | Follow Tools/maintenance/mutation-survivors.md | Auto-merge on green |
| Weekly performance check | Monday, before the digest (15:13 UTC) | Follow Tools/perf-bench/weekly-task.md | Its own rules (below) |
| Weekly dead-code review | Monday, after the Sunday scan | Existing task; see docs/dead-code-scan.md | Yes |
| Monthly audit rotation | Saturdays, one audit a week | Existing task (`monthly-audit-rotation`); its procedure is not yet in the repository | Files issues only |

The docs and UI audits in the root `CLAUDE.md` ("Subagents and Hooks") belong
in the monthly audit rotation. The dead-code review and the audit rotation
were set up before this folder existed, so their prompts do not point here
yet; moving their procedures into this folder is a follow-up.

The times follow the CI jobs that each task reads. `dependency-failure.yml`
is event-driven (it runs after a Dependabot pull request's checks, and the
Dependabot updates come on Mondays), so the task polls daily for open
`dependency-update-failed` issues. The others follow `swift-currency.yml`
(Monday 07:15 UTC), `mutation-weekly.yml` (Tuesday 06:00 UTC), and the weekly digest (Monday
15:13 UTC). The performance task must run on the same machine every week,
because its wall times are compared with a baseline measured there.

## Rules every task follows

- Read the root `CLAUDE.md` first and load the `steward` skill before
  driving a pull request.
- A task in this folder that merges does so by enabling auto-merge (squash)
  on its pull request, and GitHub merges it when every required check
  passes. (The performance task merges by hand under the stricter rules in
  its own file, because it must check each deploy before the next merge.)
  A task never merges a red pull request by hand, and never merges one it did not open,
  except a Dependabot pull request named in a `dependency-update-failed`
  issue. Every merge to `main` deploys to production.
- Never skip, disable or quarantine a test, and never loosen a check, to get
  green. A job gets one re-run at most. No empty commits, and no closing and
  reopening a pull request to kick CI.
- Do not edit an existing file under `Tests/`; the ask-before-test-edit hook
  denies it when no person answers prompts. Add a new test file, or name the
  exact edit in the pull request and leave that change for the maintainer.
- One changelog fragment per pull request in `changelog.d/`. Never touch
  `VERSION`, `Sources/Core/ChickadeeVersion.swift` or `CHANGELOG.md`.
- End every GitHub comment and issue the task writes with the Claude Code
  footer.
- Finish with a short report: what was found, what was opened or merged, and
  what is left for the maintainer.

## Setting a task up

In the Claude desktop app on the work machine, create a scheduled task with
the schedule above, the Chickadee checkout as its folder, the GitHub
connector, and the one-line prompt from the table. The performance task also
needs the `Chickadee_Admin` connector.
