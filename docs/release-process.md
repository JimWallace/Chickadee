# Release process

This repo assigns versions **at merge time**, not in PRs. The goal is to stop
concurrent PRs (and parallel agents) from colliding on `VERSION`,
`Sources/Core/ChickadeeVersion.swift`, and `CHANGELOG.md` — those three files,
each hand-edited to a specific next number, were a guaranteed text conflict and
the main source of rebase/renumber thrash.

## What a PR does now

1. **Do not edit** `VERSION`, `Sources/Core/ChickadeeVersion.swift`, or
   `CHANGELOG.md`.
2. **Add one fragment** under `changelog.d/` describing your change
   (see [`changelog.d/README.md`](../changelog.d/README.md)). New files never
   conflict, so two PRs in flight no longer fight over the changelog.
3. Open the PR with a normal descriptive title (no `vX.Y.Z:` prefix needed).

Preview what your fragments will become:

```bash
scripts/assemble-release.sh --dry-run
```

## What happens on merge (automatic)

`.github/workflows/auto-release.yml` runs on every push to `main`:

1. `scripts/assemble-release.sh` computes the next version (current `VERSION`
   + 1 patch), folds all `changelog.d/` fragments into a new `## [x.y.z]`
   section in `CHANGELOG.md`, bumps `VERSION` + `ChickadeeVersion`, and deletes
   the consumed fragments.
2. The bot commits `chore(release): vX.Y.Z` to `main` and pushes a `vX.Y.Z`
   tag.
3. The tag triggers the existing `release.yml` (GitHub Release from the
   CHANGELOG section) and the tag build in `docker-build.yml`.

A merge with **no** fragments doesn't cut a release — nothing is tagged. So a
docs-only or trivial PR can either skip a fragment (no release) or include one
(rolls into the next version). Version assignment is the single, serialized
step (`concurrency: auto-release`), so two quick merges can't race.

`scripts/check-version.sh` still enforces `VERSION == ChickadeeVersion.current`;
the release script writes both together, so they never drift.

## Merge queue (optional, requires repo settings)

A merge queue serializes merges and **re-tests each PR against the real
pre-merge `main`**, catching *semantic* conflicts that text-conflict avoidance
can't (a PR that was green against a stale `main`). The CI workflows already
declare the `merge_group:` trigger so they run in the queue.

Enabling it is a **repo-settings change you must make** (it can't live in a
workflow file):

1. **Settings → Rules → Rulesets** (or Branches) → edit the `main` ruleset and
   add **two** rules: **"Require merge queue"** *and* **"Require status checks
   to pass"**. A merge-queue rule on its own with no other active rule can leave
   a PR showing as queued while nothing processes it.
   - **Only require checks that actually run on `merge_group`** — currently the
     `Swift Tests` jobs (`format-lint`, `build`, `build-and-verify`,
     `api-tests`, `api-tests-postgres`, `core-tests`, `worker-tests`,
     `browser-runner-tests`) and `Analyze (javascript-typescript)`. Requiring a
     check from a workflow that has *no* `merge_group:` trigger (e.g.
     `docker-build`, `jupyterlite`) makes the queue wait forever for a check
     that never starts. Add `merge_group:` to those workflows first if you want
     them gating the queue.

**Troubleshooting "queued but not moving":**

- `gh api graphql -f query='{repository(owner:"OWNER",name:"REPO"){mergeQueue(branch:"main"){entries(first:5){nodes{state pullRequest{number}}}}}}'`
  returning `mergeQueue: null` means **no queue is actually configured** — the
  ruleset is missing the "Require merge queue" rule. Add it.
- If the queue exists but a PR sits at `state: PENDING` forever, a required
  check isn't running on the `merge_group` event. Check
  `gh api 'repos/OWNER/REPO/actions/runs?event=merge_group'`; if it's empty, the
  required workflows lack the `merge_group:` trigger.
2. **Bypass for the release bot.** Protecting `main` will otherwise reject the
   `auto-release` bot's direct push (step 2 above). Either:
   - add the bot identity (e.g. a GitHub App or a fine-grained PAT used by
     `auto-release.yml`, swapped in for the default `GITHUB_TOKEN`) as a
     **bypass actor** on the ruleset, **or**
   - switch the release flow to derive the version at build time instead of
     committing it back (a larger change — `ChickadeeVersion.current` is a
     compile-time constant consumed in ~10 files, so it currently has to be a
     committed source value).

Until that bypass is configured, leave `main` unprotected so `auto-release` can
push, or expect the release commit/tag to fail.

## Rolling it back

- Disable auto-releases: delete or disable `.github/workflows/auto-release.yml`.
- Cut a manual release the old way: bump `VERSION` + `ChickadeeVersion`, run
  `scripts/assemble-release.sh --version X.Y.Z` (or hand-edit `CHANGELOG.md`),
  commit, and `git tag -a vX.Y.Z && git push origin vX.Y.Z`.
