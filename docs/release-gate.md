# The release gate

Decided on 2026-11-16, for 0.6 (issue #3061, item 5). Until now a green merge to
`main` reached production on its own in 10 to 15 minutes. That was right for a
system with one course. With several courses running live class activities, a
change that breaks what a student's browser has cached or how a grade is
computed must reach production only when someone chooses the moment.

The gate has two halves:

- **Contract changes ship only in a minor or a major,** which is cut by hand.
- **Production deploys by mode,** set by an admin on the admin page. In the
  default mode a patch deploys on its own and a minor waits for an admin to
  approve it.

Blue-green deployment (`docs/zero-downtime-deploy.md`) is unchanged. The gate
decides *whether* and *when* a release deploys, never *how*.

## The student contract

The student contract is what a student's work depends on between two visits:
the kernel files their browser has cached, and the meaning of a grade. One file
lists its paths, `scripts/contract-paths.txt`, one pattern per line, read by
every check below:

```
Public/jupyterlite/
Public/vendor/
Public/runner-wasm/
Tools/jupyterlite/environment-*.yml
Tools/jupyterlite/requirements.txt
Tools/jupyterlite/jupyter-lite.json
Sources/RunnerCore/
Tests/Fixtures/output-contract.json
```

Compatibility removals (a route, a wire field, a stored format, an env var) are
part of the contract too. `docs/release-process.md` already reserves them for a
minor, and a reviewer enforces that; the path list cannot.

A new path joins the list when a change to it would break a student who has the
old version open or cached.

## Contract changes ship only in a minor

**At merge time.** A pull request that changes a contract path fails the check
`contract-change` unless it carries the label `minor-release`. The label is the
author saying "this ships in the next minor". The check runs on
`pull_request` and on `labeled` / `unlabeled`, and names the paths it found.

Pull requests that re-vendor a kernel (`revendor-kernels.yml`) and the
JupyterLab dependency updates no longer enable auto-merge. They are opened with
the `minor-release` label and wait. The steward leaves them alone.

**At release time.** `auto-release.yml` compares the commits since the last
release tag with `scripts/contract-paths.txt`. When any of them changed a
contract path, it cuts no release: no patch, no minor. It writes why in the job
summary and opens (or updates) one issue labelled `minor-needed`, which names the
pull requests that carry the contract change. Fragments keep accumulating in
`changelog.d/`.

**Cutting the minor** is the manual step in `docs/release-process.md`
("Cutting a minor (or major) release"), unchanged:
`scripts/assemble-release.sh --version 0.X.0`, a commit with the
`chore(release):` prefix, and the tag pushed from a human account. Auto-release
resumes at `0.X.1` on the next merge.

**The order of a minor.** Contract pull requests merge together, just before
the cut, because while one sits on `main` no release of any kind is cut:

1. Merge the labelled contract pull requests.
2. Cut the minor by hand.
3. The deployer holds it (in the default mode).
4. An admin approves it on the admin page, at a time with no lecture running.

## Deploy modes

| Mode | Patch | Minor | Major |
|---|---|---|---|
| Autonomous | deploys | deploys | waits for approval |
| **Gated minors (default)** | deploys | waits for approval | waits for approval |
| Manual | waits for approval | waits for approval | waits for approval |

**Pause** is a switch beside the mode, not a fourth mode. While paused, nothing
deploys, an approved release included. It replaces the host command that
`docs/lecture-day-runbook.md` uses before a lecture.

A major always waits, whatever the mode: the deployer's existing gate.

**Releases accumulate.** The deployer reads only the newest release, and each
release is cumulative, so the release that waits is always the newest one. An
approval names a version; if a newer release appears before the deployer acts
on it, the newer one is held and needs its own approval. A deploy skips straight
from what runs to what was approved. Rollback returns to what ran before.

## The deployer

`deploy/chickadee-deployer.sh` gains:

- **A mode,** stored in `$STATE_DIR/mode` (`autonomous`, `gated-minors`,
  `manual`). An absent file means `gated-minors`. `is_gated` reads it: in
  `manual` every newer release is gated; in `gated-minors` a minor or major
  bump is; in `autonomous` only a major. `CHICKADEE_DEPLOY_GATE_LEVEL` is
  retired in favour of the file; no new variable is added.
- **Pause, remembered.** Pause and resume persist in `$STATE_DIR/paused`, so a
  daemon restart (including the one after it updates its own scripts) keeps
  the state. Today `PAUSED` lives only in the shell.
- **The held release's notes.** When it holds a release, the daemon writes the
  GitHub release notes of every release between the deployed version and the
  held one to `$STATE_DIR/pending-notes.json`, so the admin page can show what
  an approval ships without calling GitHub itself.
- **`status.json`** gains `mode` and keeps `paused`.

Host commands through `command.json` keep working, and keep `rollback` and
`deploy` (a named version), which only the host can send.

**How it reaches production.** The daemon brings its own scripts to the commit
of each release it deploys and restarts on them. So the gate ships as an
ordinary patch: the old daemon deploys it as usual, then restarts as the new
one, in `gated-minors`. It must land before the 0.6.0 cut, so that 0.6.0 is the
first minor the gate holds.

## The admin page asks; the daemon decides

The app reads the state folder through a read-only mount (`/deploy-state`), so
that a compromised app can never move traffic. That stays. The app gets one more
mount, read-write, for requests only: `$STATE_DIR/requests` on the host, mounted
at `/deploy-state/requests` (`bluegreen-deploy.sh`). The path is derived from the
existing state directory, so no new variable is needed.

The app writes one JSON file per request. The daemon reads them each cycle,
oldest first, deletes each, and accepts exactly these:

| Request | Accepted when |
|---|---|
| `{"request":"approve","version":"vX.Y.Z"}` | `vX.Y.Z` is the release the daemon is holding |
| `{"request":"mode","mode":"autonomous"}` (or `gated-minors`, `manual`) | always |
| `{"request":"pause"}`, `{"request":"resume"}` | always |

Anything else is refused and written to the history: an unknown request, a
`rollback` or `deploy`, a version that is not the held one, a file over 4 KB.
Each accepted or refused request is a line in `history.jsonl`, with the admin's
username, which the app writes into the request.

**What a compromised app can do through this channel:** deploy, sooner than
planned, a release that CI built and the deployer would deploy anyway; change
the mode; pause. It cannot run an image that is not a release, choose an older
version, or roll back.

## The admin page

A "Deployment" section on the admin panel, for admins only:

- **What runs:** the deployed version, the mode, paused or not, the daemon's
  state and its last update (`status.json`).
- **What waits:** the held release, the release notes between the deployed
  version and it (`pending-notes.json`), and a flag on every entry that came
  from a `minor-release` pull request.
- **Approve:** the admin types the held version to confirm. The page then says
  "approved, deploys within 5 minutes" and follows `status.json`.
- **Mode:** the three modes, changeable in both directions.
- **Pause / Resume.**
- **History:** the last deploys, rollbacks and requests (`history.jsonl`).

Every action is a POST with CSRF, writes an audit-log entry
(`AuditLogger`, category deploy), and writes one request file. The page never
shows a button for rollback; it shows the host command, for reference.

The admin diagnostics MCP stays read-only. `get_deploy_status` reports the mode
and the held release.

## What changes in the docs

- `CLAUDE.md`, "Deployment & CI/CD": a green merge reaches production on its
  own only in the modes that allow it; a contract change waits for a minor.
- `docs/release-process.md`: a minor is also how a contract change ships, and
  auto-release stops at a contract change.
- `docs/zero-downtime-deploy.md`: the modes, the request channel, the second
  mount.
- `docs/lecture-day-runbook.md`: pause and resume on the admin page.

## Not in this design

- **Holding deploys during a live class session.** Pause covers a lecture, and
  the automatic version was judged not worth its complexity.
- **Rollback from the admin page.** It stays a host action.
