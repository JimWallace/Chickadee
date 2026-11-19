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
Public/grading-shared.js
Public/python-grading-shared.js
Public/r-grading-shared.js
Public/lua-grading-shared.js
Public/octave-grading-shared.js
Public/xeus-kernel-shared.js
Tools/jupyterlite/environment-*.yml
Tools/jupyterlite/requirements.in
Tools/jupyterlite/requirements.txt
Tools/jupyterlite/locks/
Tools/jupyterlite/jupyter-lite.json
Sources/RunnerCore/
Tests/Fixtures/output-contract.json
```

Compatibility removals (a route, a wire field, a stored format, an env var) are
part of the contract too. `docs/release-process.md` reserves them for a minor.
No path list can see them, so their author labels the pull request
`minor-release`, and auto-release holds on the label as it holds on a path
(below). A reviewer checks that the label is there.

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
release tag with `scripts/contract-paths.txt`, and asks GitHub for the pull
request of each. When any of them changed a contract path, or came from a pull
request labelled `minor-release`, it cuts no release: no patch, no minor. Added
on 2026-11-17 (#3061): before, the label was only read at merge time, so a
labelled removal that touched no contract path would have shipped in a patch,
and in `gated-minors` a patch deploys on its own. If GitHub cannot be asked,
the job fails rather than release. It writes why in the job
summary and opens (or updates) one issue labelled `minor-needed`, which names the
pull requests that carry the change. Fragments keep accumulating in
`changelog.d/`.

**Cutting the minor** is the manual step in `docs/release-process.md`
("Cutting a minor (or major) release"), unchanged:
`scripts/assemble-release.sh --version 0.X.0`, a commit with the
`chore(release):` prefix, and the tag pushed from a human account. Auto-release
resumes at `0.X.1` on the next merge.

**The order of a minor.** Labelled pull requests merge together, just before
the cut, because while one sits on `main` no release of any kind is cut:

1. Merge the labelled pull requests.
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
deploys, an approved release included. Pause on the admin page before a
lecture so that no cutover lands during it, and resume afterwards.

A major always waits, whatever the mode: the deployer's existing gate.

**Releases accumulate.** The deployer reads only the newest release, and each
release is cumulative, so the release that waits is always the newest one. An
approval names a version; if a newer release appears before the deployer acts
on it, the newer one is held and needs its own approval. A deploy skips straight
from what runs to what was approved. Rollback returns to what ran before.

## The deployer

`deploy/chickadee-deployer.sh` gains:

- **A release channel,** stored in `$STATE_DIR/channel` (see "Pre-release
  channel" below). Host-only.
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

## Pre-release channel

Added on 2026-11-16, in the same change: production stays gated, and the dev
server runs ahead of it. `chickadee-dev` restores a production snapshot every
night so that it can try what comes next. Without a pre-release, auto-release
cuts nothing after a contract change, so dev would stall exactly when a kernel
re-vendor most needs trying.

**A pre-release where the gate refuses.** Where `auto-release.yml` refuses a
release because a contract path changed since the last release tag, it cuts a
GitHub **pre-release** of the next minor instead: `v0.7.0-rc.1`, then
`rc.2`, and so on, one more than the last rc of that minor, on each push that
adds a changelog fragment (a docs-only or test-only merge cuts none). It
still opens or updates the `minor-needed` issue. An rc image is built only
when the tag push carries `RELEASE_TOKEN`, as for a stable release.

- The rc is a commit of its own on top of `main`'s head that changes only
  `Sources/Core/ChickadeeVersion.swift` to the rc version. Only its tag
  reaches GitHub; `main` is not changed. So `VERSION`, `CHANGELOG.md` and
  the fragments in `changelog.d/` stay where they are, and the fragments
  fold into the real minor.
- The running build reports the rc it is: `/health`, the admin banner and
  the image's `org.opencontainers.image.version` label all say
  `0.7.0-rc.N`. The server's version comparisons (`VersionComparator`) read
  only the leading `X.Y.Z`, so nothing crashes on the suffix, but they treat
  every rc of a minor and the minor itself as equal: the runner version skew
  alert does not see a dev runner one rc behind, and a `minimumRunnerVersion`
  of `0.7.0` admits an rc runner. That is acceptable on dev, the only place
  an rc runs. The deployer orders rcs correctly (below).
- `docker-build.yml` builds the tag and publishes `:sha-<commit>` of the rc
  commit, which no build of `main` publishes, and `:0.7.0-rc.N`. An rc never
  moves `:latest`, of the server image or of the arm64 runner image
  (`runner-arm64-image.yml`), because production's runners follow it. A new
  workflow that reacts to a `v*` tag must make the same exception.
- `release.yml` marks it a pre-release, never latest, with the pending
  fragments as its notes.

**A release channel on the deployer**, in `$STATE_DIR/channel`:

| Channel | Reads | Used by |
|---|---|---|
| `releases` (absent file) | GitHub `releases/latest`, which never names a pre-release | production |
| `prereleases` | the newest non-draft release in the releases list, pre-releases included | the dev server |

The channel is **host-only**. It is set by a host command
(`{"command":"channel","channel":"prereleases"}` in `command.json`) or by
writing the file. The app's request channel refuses any request to change it,
so the admin page can never point production at the pre-release channel; it
can only approve one offered rc ("Approving a pre-release on production"). The page shows
the channel read-only.

Versions order with their rc suffix: `0.7.0-rc.3` > `0.6.12`,
`0.7.0-rc.10` > `0.7.0-rc.9`, and `0.7.0` > `0.7.0-rc.3` (plain `sort -V`
gets the last one wrong). In `gated-minors` an rc of the next minor counts as
a minor bump.

**Dev runs `channel=prereleases`, `mode=autonomous`.** Both are needed: in
`gated-minors` the first rc of a minor counts as a minor and waits for
approval, so dev would stall on it. It takes each rc as it
is cut, on top of the nightly production snapshot it already restores. Dev is
where a minor is validated before an admin approves it on production. The
order of a minor becomes:

1. The labelled contract pull requests merge; each merge with fragments cuts
   an rc, and dev deploys it.
2. The rc is validated on dev.
3. The minor is cut by hand, and production holds it.
4. An admin approves it on production's admin page, at a time with no
   lecture running.

## Approving a pre-release on production

Added on 2026-11-18. Production's channel never deploys a pre-release on its
own, in any mode, and no setting makes it. But an admin may choose to put a
validated rc on production before the minor is cut, so the daemon offers one,
for an explicit approval only:

- **The offer.** On the `releases` channel, each poll the daemon also reads
  the newest non-draft pre-release. When it is newer than production and than
  the newest release, it records it in `status.json` (`prereleaseVersion`) and
  writes its notes, in the shape of `pending-notes.json`, to
  `prerelease-notes.json`. A cut minor, or the rc deploying, retires the offer.
- **The card.** The admin page shows a "Coming next" card: the rc, a
  Pre-release badge, "Runs on the dev server; deploys here only when approved.", its notes and the
  `minor-release` pull requests it carries, and the same typed-version
  approval form as a held release.
- **The approval.** `{"request":"approve","version":"vX.Y.0-rc.N"}` is
  accepted only for the offered rc. The daemon then deploys that exact
  version, through the same staging, signature check and blue-green swap as
  any release. A newer rc that appears before it acts needs its own approval.
- **An rc with no image.** While the approved rc's image is built, the
  approval waits, as a held release's does. The wait is bounded: if the image
  is still not deployable after two hours (`WAIT_STUCK_AFTER_SECS`), the
  daemon drops the approval, writes `approve expired` to the history, and
  goes on to the release path, so a patch is not held behind an rc that will
  never build. The rc stays offered; approve it again once its image exists.
- **After it.** While production runs an approved rc, the release that
  follows it in the same minor (the minor itself, or a later rc) counts as a
  minor: in `gated-minors` and `manual` it waits for approval, because it
  carries whatever merged after the approved rc. In `autonomous` it deploys,
  as a minor would.

The modes are unchanged: none of them has a setting that deploys a
pre-release, and no request can change the channel.

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
| `{"request":"approve","version":"vX.Y.Z"}` | `vX.Y.Z` is the release the daemon is holding, or the pre-release it offers (`prereleaseVersion`) |
| `{"request":"mode","mode":"autonomous"}` (or `gated-minors`, `manual`) | always |
| `{"request":"pause"}`, `{"request":"resume"}` | always |

Anything else is refused and written to the history: an unknown request, a
`rollback` or `deploy`, a change of channel, a version that is neither the held release nor the offered pre-release, a file over 4 KB.
Each accepted or refused request is a line in `history.jsonl`, with the admin's
username, which the app writes into the request.

**What a compromised app can do through this channel:** deploy, sooner than
planned, a release that CI built and the deployer would deploy anyway; deploy
the newest pre-release, which CI built and signed and dev runs; change the
mode; pause. It cannot run an image that is not a release, choose an older
version or an earlier rc, or roll back.

## The admin page

A "Deployment" section on the admin panel, for admins only:

- **What runs:** the deployed version, the mode, the channel (read-only),
  paused or not, the daemon's
  state and its last update (`status.json`).
- **What waits:** the held release, the release notes between the deployed
  version and it (`pending-notes.json`), and a flag on every entry that came
  from a `minor-release` pull request.
- **Coming next:** on production, the newest pre-release, its notes and an
  approval form (`prerelease-notes.json`); see "Approving a pre-release on
  production".
- **Approve:** the admin types the held version (or the offered rc) to confirm. The page then says
  "approved, deploys within 5 minutes" and follows `status.json`.
- **Mode:** the three modes, changeable in both directions.
- **Pause / Resume.**
- **History:** the last deploys, rollbacks and requests (`history.jsonl`).

Every action is a POST with CSRF, writes an audit-log entry
(`AuditLogger`, category deploy), and writes one request file. The page never
shows a button for rollback; it shows the host command, for reference.

The admin diagnostics MCP stays read-only. `get_deploy_status` reports the mode,
the held release and the offered pre-release.

## What changes in the docs

- `CLAUDE.md`, "Deployment & CI/CD": a green merge reaches production on its
  own only in the modes that allow it; a contract change waits for a minor.
- `docs/release-process.md`: a minor is also how a contract change ships, and
  auto-release stops at a contract change.
- `docs/zero-downtime-deploy.md`: the modes, the request channel, the second
  mount.

## Not in this design

- **Holding deploys during a live class session.** Pause covers a lecture, and
  the automatic version was judged not worth its complexity.
- **Rollback from the admin page.** It stays a host action.
