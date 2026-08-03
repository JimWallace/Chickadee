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

### Downstream triggering — set `RELEASE_TOKEN` for full automation

GitHub deliberately does **not** let a tag pushed with the default
`GITHUB_TOKEN` trigger other workflows (loop prevention). So out of the box the
bot's tag will **not** fire `release.yml` (GitHub Release) or the tag build in
`docker-build.yml` (the versioned + `:latest` image your deploy pulls).

`auto-release.yml` handles this in two modes:

- **Recommended — add a `RELEASE_TOKEN` secret.** Create a fine-grained PAT with
  **Contents: read & write** on this repo and save it as the repo secret
  `RELEASE_TOKEN`. The bot pushes the tag with it, so `release.yml` **and**
  `docker-build` fire naturally — fully automated, including the `:latest`
  Docker image.
- **Fallback (no secret).** The bot uses `GITHUB_TOKEN` and explicitly
  dispatches `release.yml` (so GitHub Releases still happen), **but the
  `docker-build` tag build does not run** — `:latest` won't update on release
  until you either add `RELEASE_TOKEN` or build/push the image another way.

Until `RELEASE_TOKEN` is set, treat the per-release Docker image as a manual /
follow-up step.

`scripts/check-version.sh` still enforces `VERSION == ChickadeeVersion.current`;
the release script writes both together, so they never drift.

## What the numbers mean while we are 0.y.z

SemVer's major-version-zero rule is that nothing is promised yet ("anything
MAY change at any time"), so the slots below are this project's own policy —
adopted at the 0.5.0 cut — with the enforceable parts wired into tooling
rather than left to convention:

- **Patch — auto-cut on every merged fragment.** Routine change. A patch must
  never remove or break a compatibility surface: an env var, a route, a wire
  field, a bundle key, a stored format. Auto-release can only produce
  patches, so "a merge never breaks an operator" is structural, not a review
  item — if a PR retires something, it is not a patch (see the next bullet)
  and must wait.
- **Minor — deliberate and manual.** An era boundary, a batch of
  compatibility removals, or both. 0.5.0 was both: the capstone on the first
  full course offering *and* the retirement of the pre-0.5 shims
  (`WORKER_SHARED_SECRET`, `/admin/workers`, the bundle `isOpen` write side,
  …). Removals accumulate behind deprecation warnings on patches and land
  together at the next minor, where the changelog announces them in one
  place.
- **Major — manual, and deployer-gated.** Reserved. The deploy daemon holds
  major bumps for human approval, so 1.0.0 will be the first release that
  cannot reach production without an explicit operator sign-off. 1.0 is also
  the point where external contracts — the `.chickadee` bundle format, the
  MCP surfaces, the runner wire protocol — would become promises to parties
  other than ourselves; until some other institution consumes one of those,
  0.y.z's freedom is doing no harm.

## Cutting a minor (or major) release — manual by design

Auto-release is **patch-only by construction**: `assemble-release.sh` computes
`major.minor.(patch + 1)` whenever it is invoked without `--version`, and
`auto-release.yml` never passes one. Fragment categories (`### Added`,
`### Removed`, …) are folded into the changelog verbatim — they carry **no**
bump semantics — and there is no marker, label, or commit-prefix scan. No
sequence of merges can ever produce `0.5.0` on its own; that is a deliberate
human decision, made like this:

1. Make sure at least one fragment exists in `changelog.d/` — usually a short
   milestone note written for the occasion. (The script refuses to release an
   empty fragment set, `--version` or not.)
2. On an up-to-date local `main`:

```bash
scripts/assemble-release.sh --version 0.5.0
```

   This folds the fragments in under a `## [0.5.0]` heading, writes `VERSION`,
   regenerates `ChickadeeVersion.swift`, and deletes the consumed fragments.
3. Commit with the exact prefix the workflow guard looks for, then tag:

```bash
git commit -am "chore(release): v0.5.0"
git tag -a v0.5.0 -m "Chickadee v0.5.0"
git push origin main v0.5.0
```

   The `chore(release):` prefix is what stops `auto-release.yml` from firing on
   the push and immediately cutting a redundant 0.5.1.
4. Push from your own account (or any PAT-authenticated remote): a
   human-pushed tag triggers `release.yml` and the `docker-build.yml` tag build
   normally. (Only tags pushed with the workflow `GITHUB_TOKEN` are suppressed
   by GitHub's loop prevention.)
5. Done — the deployer treats a minor bump as auto-deployable (only **major**
   bumps are held for approval), and auto-release resumes at `0.5.1` on the
   next merged fragment.

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
