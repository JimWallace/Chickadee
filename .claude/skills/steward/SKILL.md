---
name: steward
description: >
  Repo-specific guidance for an agent that drives a Chickadee pull request to a
  mergeable state. Read it on every CI failure, red or cancelled check, merge
  conflict, review comment and PR check-in, and when a merged fix does not
  show in production. It covers the CI flake families, the guards to run
  before a push, how to verify a deploy-script fix, and how proactive to be.
---

# Stewarding a Chickadee pull request

This file is read when an agent wakes on a CI failure or review comment for a
Chickadee PR. It covers what this repository does differently, and how
proactive to be. It does not grant anything: the harness rules it sits under
still forbid skipping or quarantining a test, pushing an empty commit to kick
CI, rewriting history on someone else's branch, and approving or merging.

This file assumes that `CLAUDE.md` is loaded, and it does not repeat it. The
rules on versions, environment variables, tests, shell snippets and the
authoring voice are there. Obey them on every push.

## On each wake

Copy this checklist and complete it in order:

```
PR wake:
- [ ] 1. Read the PR head: merge state, CI on the latest commit, open threads
- [ ] 2. Merge conflict: merge the base branch in and resolve it
- [ ] 3. Red check: apply "Read a red check" below before you believe it
- [ ] 4. Review threads: fix each one, or reply with the reason you do not
- [ ] 5. Before a push: run the guards for each layer you touched
- [ ] 6. Before a push: confirm the version files do not diverge from main
- [ ] 7. UI files touched: run the ui-review agent
- [ ] 8. Push, then read CI on the new head
```

## Read a red check before believing it

Start at `docs/ci-flakiness.md` before you diagnose a red check on a PR that
did not touch the failing area. Its header says which families are open and
which are closed.

**A job `cancelled` at its ceiling has two opposite shapes.** Read Family 6,
then Family 5. A wedge (Family 6) stops: nothing finishes after the first
minute. A collapse (Family 5) runs slowly and keeps finishing tests. One
`[ci-pressure]` telemetry line in the job log separates them: `scopes=0.0/min`
with `self cpu=0.0%` is the wedge. Also look at the other lane on the same
commit: if `api-tests` is cancelled, did `api-tests-postgres` pass? Family 6 is
fixed, and Family 5 is closed for monitoring, so a new occurrence of either is
a finding. Record it in that doc with the telemetry.

**Do not read anything into per-test or per-suite durations in that log.**
Swift Testing starts a test's clock when it is *scheduled*, not when it gets a
parallelization slot, so a healthy run's median test already reports ~80 s and
every suite ends at about the run's total. Chasing a "slow test" there is
chasing an artifact.

**A `build` job that exits 139 at `[Planning 1 / N]`** before any compile is
Family 7, an upstream SwiftPM crash. The answer is one `/rerun-failed`, never a
read of the diff.

## Confirm the version files did not move

`CLAUDE.md` §"Versioning" has the rule. If a base merge brings `VERSION`,
`CHANGELOG.md` or `Sources/Core/ChickadeeVersion.swift` in from `main`, that is
expected. Confirm that your branch does not *diverge* from main on them:

```
git diff origin/main --stat -- VERSION CHANGELOG.md Sources/Core/ChickadeeVersion.swift
```

Empty output is the pass.

## Run the guards before pushing, not after

CI's `format-lint` job is a long list of scripts, and every one of them runs
locally in seconds. A push that turns it red costs a cycle for something
mechanical. At minimum, for the layers you touched:

| Touched | Run |
|---|---|
| Swift | `scripts/format.sh` then `scripts/lint.sh`, `scripts/swiftlint.sh` |
| `Public/styles.css`, page JS | `scripts/check-styles.sh` |
| `Sources/APIServer/Views/` | `swift test --filter ElementaryPageGuardTests`, `scripts/swiftlint.sh` |
| a guard script itself | `scripts/check-guards.sh` |
| `.claude/skills/`, `.claude/skill-evals/` | `scripts/check-claude-skills.sh` |
| `docker-compose.yml`, `Dockerfile`, `deploy/` | `scripts/check-docker-build-context.sh`, `scripts/ci-compose-env.sh --check` |

`scripts/format-lint.sh` runs every step of the job at once.

## The UI review is in CI too

`CLAUDE.md` makes the `ui-review` agent unconditional for a UI change. CI runs
the same brief on every pull request that touches those paths
(`.github/workflows/ui-review.yml`). The workflow posts its report on the PR
and fails on a `changes requested` verdict. Its findings are bot findings, so
verify each one and push the fix. If the agent cannot run in your session, the
workflow is the review; no note in the PR is needed.

## Never change an existing test to get green

Ask the maintainer before you change an existing test. Adding a test is always
fine. Altering an assertion someone else wrote is a question, not a judgement
call, and this outranks any urge to get a red check green. The
`ask-before-test-edit.py` hook asks too, but obey the rule without it.

## A new check needs a fixture

`scripts/check-guards.sh` applies each fixture's defect and fails the build if
the guard *passes*. The house rule is that a check never seen to fail is not a
check, and it has been paid for four times. This generalises beyond guards:
when adding any check, break the thing it watches and confirm it goes red.

## Repository prose

Repository prose, including PR bodies and commit messages, is written in
ASD-STE100 English: short sentences, one idea each, plain vocabulary.

## How proactive to be

**Ops and infrastructure fixes** — deploy scripts, health rules, CI, backup
and restore — are wanted promptly. Diagnose, fix, verify, push. Do not sit on
a validated fix waiting for permission.

**Changes whose defaults land on every deployment** — a `docker-compose.yml`
default, a resource limit, a security posture — are the maintainer's call.
Open the PR, say plainly what the default would become and who it affects, and
let them decide.

**A fix for a production incident outranks tidiness.** Ship the fix; open a
second PR for the cleanup it revealed.

## Verify against the deployment, not against the repository

Two facts that have each cost a day:

**The deploy scripts run from a git clone on the host, not from the image.**
`bluegreen-deploy.sh`, `chickadee-deployer.sh`, `snapshot.sh` and `restore.sh`
all execute from that checkout. The daemon moves the clone to a release's
commit only after it stages that release's image. A merge with no
`changelog.d/` fragment cuts no release, so it never reaches the clone. A clone
with local changes is left alone (`deployer-update skipped`), and a failed
fetch keeps the old scripts (`deployer-update failed`). So the script that ran
may not be the script on `main`. Never conclude that a deploy script is buggy
from reading `main`: compare `scriptsRevision` from
`Chickadee_Admin:get_deploy_status` with your merge commit, and read
`Chickadee_Admin:get_deploy_history` for the update events.

**`:latest` lags a release tag.** The deployer targets a GitHub release while
pulling `:latest`, and the image build takes ~15 minutes. A deployer log saying
"running version now X (target release Y)" is normal during that window and is
not evidence of a failed swap.

`docs/zero-downtime-deploy.md` is the runbook. The read-only admin MCP server
is how to confirm a fix is live and behaving. Use its tools by their full
names: `Chickadee_Admin:get_deployment_info`,
`Chickadee_Admin:get_deploy_status`, `Chickadee_Admin:get_deploy_history`,
`Chickadee_Admin:get_health_alerts` and `Chickadee_Admin:query_logs`.

## When a fallback is the bug

A recurring shape here, most recently across four deploy scripts at once: code
asks for something, gets an empty answer, and takes a fallback that produces a
plausible wrong value instead of failing. A backup script read `sqlite` from a
default on a Postgres host and refused to run for 82 nights.

When touching this kind of code, ask what the fallback does when the primary
lookup returns nothing *legitimately*, and make sure the wrong answer is
distinguishable from the right one.
