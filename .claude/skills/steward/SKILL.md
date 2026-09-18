---
name: steward
description: >
  Repo-specific guidance for an agent driving a Chickadee pull request to a
  mergeable state. Read on every CI failure, review comment and check-in.
---

# Stewarding a Chickadee pull request

This file is read when an agent wakes on a CI failure or review comment for a
Chickadee PR. It covers what this repository does differently, and how
proactive to be. It does not grant anything: the harness rules it sits under
still forbid skipping or quarantining a test, pushing an empty commit to kick
CI, rewriting history on someone else's branch, and approving or merging.

## Read a red check before believing it

**`api-tests` reporting `cancelled` at its 25-minute ceiling is usually not
your diff.** `docs/ci-flakiness.md` Family 5 describes it: a throughput
collapse that looks identical to a wedge. Three tells decide it, and all three
are cheap:

- Were tests still *completing* at the tail of the log? A wedge stops; a
  collapse keeps finishing tests slowly.
- Did **`api-tests-postgres`** pass? Same target, same commit, different lane.
- What do the `[ci-pressure]` telemetry lines say?

**Do not read anything into per-test or per-suite durations in that log.**
Swift Testing starts a test's clock when it is *scheduled*, not when it gets a
parallelization slot, so a healthy run's median test already reports ~80 s and
every suite ends at about the run's total. Chasing a "slow test" there is
chasing an artifact.

Start at `docs/ci-flakiness.md` before diagnosing any red check on a PR that
did not touch the failing area. Five flake families are documented; two are
open.

## Never bump the version

A PR **must not touch** `VERSION`, `Sources/Core/ChickadeeVersion.swift`, or
`CHANGELOG.md`. Hand-editing those to a hardcoded next number is what used to
make every concurrent PR conflict.

Add **one** fragment under `changelog.d/` instead — see `changelog.d/README.md`
— and preview with `scripts/assemble-release.sh --dry-run`. The merge-time
`auto-release` workflow computes the version, folds the fragments in, and tags.

If a base merge brings those three files in from `main`, that is fine and
expected. Confirm your branch does not *diverge* from main on them:

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
| `Resources/Views/`, `Public/styles.css`, page JS | `scripts/check-styles.sh` |
| a guard script itself | `scripts/check-guards.sh` |
| `docker-compose.yml`, `Dockerfile`, `deploy/` | `scripts/check-docker-build-context.sh`, `scripts/ci-compose-env.sh --check` |
| Leaf templates | `scripts/check-leaf-semantics.sh` |

`scripts/swiftlint.sh` passes `--strict`: every warning fails the build. If a
structural threshold (say `function_body_length`) starts causing legitimate
friction, raise it in `.swiftlint.yml` rather than dropping `--strict`.

## The UI review is not optional

Any change touching `Resources/Views/`, `Public/styles.css`, or a page-wiring
`Public/*.js` gets the **`ui-review` agent**, unconditionally and without
asking. The guards prove a value is on the palette and a class has a rule;
they cannot see a component that duplicates the vocabulary under a new name,
an idiom heavier than the situation needs, or copy that runs past house
length. Every style regression so far has been mechanically legal.

If the agent is genuinely unavailable, say so plainly in the PR rather than
letting its absence pass unmentioned.

## Do not add an environment variable

Standing rule, server (`AppConfig`) and runner (`RunnerDaemonConfig`) alike. A
new variable has to be set correctly in `.env.example`, `docker-compose.yml`,
the systemd units, the deploy runbook and the operator's head — and is
silently absent everywhere it was not added, which is the failure mode env
vars are worst at surfacing.

Use a CLI flag on `chickadee-runner` (as `--sandbox` and `--max-jobs` do),
derive the value from something already known, or detect the condition at
runtime. If one looks genuinely unavoidable, ask — do not add it and mention
it afterwards.

## Tests

- **Swift Testing only.** `scripts/no-new-xctest.sh` blocks a new
  `import XCTest`.
- **Never change an existing test without asking the maintainer first.** Adding
  tests is always fine; altering an assertion someone else wrote is a question,
  not a judgement call. This outranks any urge to get a red check green.
- **No force unwraps**, in tests either. Use `try #require(value)`.
- **A new guard needs a fixture.** `scripts/check-guards.sh` applies each
  fixture's defect and fails the build if the guard *passes*. The house rule is
  that a check never seen to fail is not a check, and it has been paid for four
  times. This generalises beyond guards: when adding any check, break the thing
  it watches and confirm it goes red.

## Prose

Instructional text in assignment content follows the authoring-voice guide in
`CLAUDE.md`: imperative and declarative, no exclamation marks, no emoji, no
second-person emotional narration. It is duplicated verbatim in
`MCPServerInstructions.authoringVoice` — edit both or neither.

Repository prose, including PR bodies and commit messages, is written in
ASD-STE100 English: short sentences, one idea each, plain vocabulary.

Two mechanical traps in templates, both of which fail silently:

- **Never write Leaf tag syntax in template prose or comments.** Leaf's lexer
  has no notion of an HTML comment. A bare structural tag name in a comment is
  a 500 at render; `#(field)` in a comment is *interpolated into the served
  HTML*. Say "the extend" or "an `extend(...)` include".
- **Leaf resolves no Swift properties.** `#if(rows.isEmpty)` on an array is nil,
  which never fires, and `#if(!rows.isEmpty)` always fires. Use the `count` tag:
  `#if(count(rows) == 0)`. `scripts/check-leaf-semantics.sh` enforces it.

## Shell snippets

The maintainer runs zsh with `interactive_comments` off. In anything meant to
be pasted into a terminal — chat, a PR body, a `docs/` runbook:

- No inline `#` comments on a command line.
- No apostrophes in explanatory text inside a code block.
- One plain command per line, with the explanation in prose outside the block.

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

**The deploy scripts run from a git clone on the host, and nothing in the
pipeline updates it.** `bluegreen-deploy.sh`, `chickadee-deployer.sh`,
`snapshot.sh` and `restore.sh` all execute from that checkout. A merged fix to
any of them does **not** reach production through the image. The script that
ran may not be the script in this repository — so never conclude a deploy
script is buggy from reading `main`; reproduce it, or check what the host
actually has.

**`:latest` lags a release tag.** The deployer targets a GitHub release while
pulling `:latest`, and the image build takes ~15 minutes. A deployer log saying
"running version now X (target release Y)" is normal during that window and is
not evidence of a failed swap.

`docs/zero-downtime-deploy.md` is the runbook. The read-only admin MCP
(`get_deployment_info`, `get_deploy_status`, `get_health_alerts`, `query_logs`)
is how to confirm a fix is live and behaving.

## When a fallback is the bug

A recurring shape here, most recently across four deploy scripts at once: code
asks for something, gets an empty answer, and takes a fallback that produces a
plausible wrong value instead of failing. A backup script read `sqlite` from a
default on a Postgres host and refused to run for 82 nights.

When touching this kind of code, ask what the fallback does when the primary
lookup returns nothing *legitimately*, and make sure the wrong answer is
distinguishable from the right one.
