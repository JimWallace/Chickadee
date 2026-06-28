# Zero-Downtime Deployment

Chickadee deploys used to recreate the single `server` container in place
(`docker compose pull && up -d`), which took the site down for ~60 s on every
update. This document describes the move to **zero-downtime blue-green deploys**,
driven automatically by a host-side controller and observable/overridable through
the admin MCP surface — so new builds ship periodically and transparently to
students.

It is staged so that no automation is ever wired onto a swap that has not been
proven by hand.

---

## The problem (what caused the ~60 s gap)

With one `server` container bound directly to a host port, an update was
necessarily stop-old → start-new → boot → healthy. Three things made "boot" slow,
and one made overlap impossible:

1. **Asset re-copy.** The entrypoint `rm -rf`'d and `cp -r`'d `Public/`,
   `Resources/`, `docs/` (~586 MB, mostly the vendored Pyodide) into the data
   volume on every start. *(Fixed in Phase 0.)*
2. **No proxy seam.** The host nginx pointed `proxy_pass` straight at
   `127.0.0.1:8080`, so two containers could not run at once.
3. Migrations (and, with SSO, OIDC discovery) run before `/health` goes green.

The fundamental enabler for a real fix is **PostgreSQL**: two app versions can
hold connections to the same database at once (MVCC), which is unsafe on a single
SQLite file. Prod runs Postgres as a compose `db` service, so blue-green is viable.

---

## Architecture

```
  ┌─ chickadee-server (app container) ─────────┐
  │  admin MCP tools: get_deploy_status,        │   read/write small JSON
  │  pause/resume, approve_major, rollback      │   files on a shared dir
  │  (NO docker access)                          │   (bind mount)
  └─────────────────────────────────────────────┘
                     │ intent / status (files)
                     ▼
  ┌─ host: chickadee-deployer (systemd, shell) ┐   owns docker + nginx
  │  • polls GitHub Releases for a new tag      │
  │  • SemVer gate (auto non-major / hold major)│
  │  • snapshot.sh (safety net)                 │
  │  • bluegreen-deploy.sh: start → health-gate │   ← the "can't bring it
  │    → flip nginx → drain → stop old          │     down" invariant lives here
  │  • auto-rollback if new never goes healthy  │
  └─────────────────────────────────────────────┘
```

**The cardinal rule:** the component that performs the swap is *outside* the
container it swaps, and the app **never** gets the Docker socket (that would be
host root for a process that accepts student uploads). The app only ever
*expresses intent*; the privileged host daemon does the work.

### Decisions

| Decision | Choice | Why |
|---|---|---|
| Orchestration location | Host-side daemon, **not** in the app | App must never hold the Docker socket |
| Daemon form | **Shell + systemd** (not a Swift binary/container) | Keeps the host toolchain-free; tiny, auditable; no socket-in-container |
| App ⇄ daemon channel | **Files on a shared bind-mount dir** | No DB coupling, no new network surface, no privilege leak |
| Initiation | **Fully automatic CD** | New release → auto blue-green; MCP for oversight/rollback |
| Version source | **GitHub Releases / the release tag `vX.Y.Z`** | The project's actual source of truth; the VERSION file is unreliable and is *not* used |
| Image deployed | The immutable **`:vX.Y.Z`** tag (not `:latest`) | What runs maps 1:1 to a visible release; rollback targets a release |
| Safety gate | **SemVer: auto for non-major, hold majors for approval** | Breaking changes (incl. destructive migrations) live in majors |
| MCP surface | **Admin/diagnostics**, not content-authoring | Deploying is an operator action, never an instructor one |

---

## Phase 0 — fast, overlap-safe assets (done)

The entrypoint now **symlinks** `/data/{Public,Resources,docs}` at the image's
`/app` copies instead of copying them, so boot drops from ~60 s to a few seconds
and two colors can share the data volume safely (each symlink resolves inside its
own container; creation is idempotent and atomic). See
`deploy/docker-entrypoint.sh`.

---

## Phase 1 — blue-green, manual (the proven core)

`scripts/bluegreen-deploy.sh`. This is the keystone: once a swap has been watched
working by hand, Phases 2–3 just call it.

### Topology

- The two "colors" run as plain `docker run` containers **alongside** the existing
  compose stack — `chickadee-server-blue` on `127.0.0.1:8081`,
  `chickadee-server-green` on `127.0.0.1:8082`. The compose `db` and `runner`
  stay under compose, untouched.
- **Configuration source of truth stays in compose.** The script resolves the
  `server` service environment via `docker compose config` and passes it to the
  color with `--env-file` — no env duplication, no drift.
- The colors join the existing `chickadee_chickadee` network (so they reach `db`)
  and mount the existing `chickadee_chickadee-data` volume.
- **The runner needs no changes**: it talks to the server over the public URL
  (`https://chickadee.uwaterloo.ca`), so it follows the nginx flip automatically.
- "Active" = the port the nginx upstream points at. It starts at `:8080` (the
  legacy compose `server`), moves onto a color on the first deploy, then colors
  alternate. The legacy server is left running as a fallback and is never
  auto-stopped.

### One-time nginx setup

Make nginx route through a rewritable upstream instead of a hard-coded port
(see `deploy/nginx-chickadee-upstream.conf`):

1. Install `deploy/nginx-chickadee-upstream.conf` as
   `/etc/nginx/conf.d/chickadee-active-upstream.conf` (the script also creates it
   pointing at `:8080` if missing).
2. In `/etc/nginx/sites-available/chickadee`, change every
   `proxy_pass http://127.0.0.1:8080;` to `proxy_pass http://chickadee_backend;`.
3. `sudo nginx -t && sudo nginx -s reload`.

After this, deploys only ever rewrite that one upstream line.

### The script

```bash
sudo scripts/bluegreen-deploy.sh status                  # active/idle + health
sudo scripts/bluegreen-deploy.sh deploy                  # pull :latest, swap to it
sudo CHICKADEE_IMAGE=ghcr.io/jimwallace/chickadee:vX.Y.Z scripts/bluegreen-deploy.sh deploy
sudo scripts/bluegreen-deploy.sh deploy --dry-run        # print actions only
sudo scripts/bluegreen-deploy.sh rollback                # flip back to the previous color
```

It: resolves env from compose → (re)creates the idle color with the new image →
**waits for the idle color's `/health`** → snapshots an nginx-include backup →
flips the upstream + `nginx -t && nginx -s reload` (restoring the include if
validation fails) → drains → stops the old color (kept, not removed, for fast
rollback). The live color is never stopped before the new one is healthy.

### Recommended first test (non-disruptive)

Because the colors run beside the live stack on different ports, you can prove the
mechanism without moving any student traffic:

1. `sudo scripts/bluegreen-deploy.sh deploy --dry-run` — read the planned actions.
2. Do the one-time nginx upstream setup above.
3. `sudo scripts/bluegreen-deploy.sh deploy` — brings up a color on 8081, health-
   checks it, flips nginx to it. Your old `:8080` server stays up as a fallback.
4. `curl -sf https://chickadee.uwaterloo.ca/health` and click around.
5. `sudo scripts/bluegreen-deploy.sh rollback` to flip straight back if anything
   looks off. When confident, retire the legacy `:8080` server at your leisure.

### Safety invariants

- Blue keeps serving the whole time; nginx flips **only after** the new color
  passes `/health`.
- New color unhealthy within the timeout → abort, remove the new color, active
  untouched. Zero student impact.
- `nginx -t` fails → restore the previous upstream include, abort.
- Old color is only stopped after the flip + a drain delay.

---

## Phase 2 — the deployer daemon (automatic CD) — IMPLEMENTED

`deploy/chickadee-deployer.sh` (shell) + `deploy/chickadee-deployer.service`
(systemd). The loop, every `POLL_INTERVAL_SECS` (default 300):

1. Reads `command.json` (operator/MCP commands — see IPC below).
2. Polls the **GitHub Releases API** (`/repos/<repo>/releases/latest`,
   unauthenticated — the repo is public) for the latest tag `vX.Y.Z`.
3. If it's not newer than the deployed version (`sort -V` compare), records
   "up to date" and sleeps.
4. Applies the **SemVer gate**: if the bump crosses `DEPLOY_GATE_LEVEL`
   (default `major` → only major bumps held; set `minor` to also hold minor
   bumps during the 0-series), it writes `pending_approval` and waits for an
   `approve` command. Otherwise it proceeds automatically.
5. Runs `scripts/snapshot.sh --label predeploy-<ver>` (Postgres dump +
   artifacts) as a safety net. `SNAPSHOT_REQUIRED=1` makes a failed snapshot
   abort the deploy; the default warns and continues.
6. Calls `bluegreen-deploy.sh deploy --yes` with `CHICKADEE_IMAGE=...:vX.Y.Z`.
   It **never** forces — if `/data/Public` isn't a symlink the guard refuses and
   the daemon records an error (fail-safe).
7. **Post-deploy verification:** watches the public `/health` for
   `POST_DEPLOY_VERIFY_SECS` (default 30); 3 consecutive failures →
   `bluegreen-deploy.sh rollback --yes`. (A swap that never goes healthy is
   already aborted by the script *before* the nginx flip, so traffic never moved
   — this covers the rarer "healthy at cutover, degrades after" case.)
8. Writes `status.json` / appends `history.jsonl` for the Phase 3 MCP surface.

### Configuration (env / `/etc/chickadee-deployer.env`)

`CHICKADEE_REPO`, `CHICKADEE_IMAGE_REPO`, `CHICKADEE_POLL_INTERVAL_SECS`,
`CHICKADEE_DEPLOY_GATE_LEVEL` (major|minor), `CHICKADEE_SNAPSHOT_BEFORE_DEPLOY`,
`CHICKADEE_SNAPSHOT_REQUIRED`, `CHICKADEE_POST_DEPLOY_VERIFY_SECS`,
`CHICKADEE_PUBLIC_HEALTH_URL`, `CHICKADEE_STATE_DIR`.

### Install

```
sudo cp deploy/chickadee-deployer.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now chickadee-deployer
journalctl -u chickadee-deployer -f
```

### Safe first run (recommended before enabling the service)

Run it in the foreground with a short interval. Since the deployed version equals
the latest release, it will just log "up to date" — no swap — so you can watch it
behave with zero risk:

```
sudo CHICKADEE_POLL_INTERVAL_SECS=30 deploy/chickadee-deployer.sh
```

Ctrl-C, then enable the service. Its first *real* auto-deploy then happens
naturally on the next merge to `main` (the next release). Pause anytime by
writing `{"command":"pause"}` to `command.json`, or `sudo systemctl stop
chickadee-deployer`.

### App ⇄ daemon IPC (files in `STATE_DIR`)

- `command.json` — operator/MCP → daemon: `{"command":"pause|resume|approve|rollback|deploy","version":"vX.Y.Z"}` (consumed each cycle).
- `status.json` — daemon → readers: `state`, `deployedVersion`, `latestSeen`, `detail`, `paused`, `updatedAt`.
- `history.jsonl` — append-only deploy log.
- `deployed_version` — the daemon's source of truth for what is live.

---

## Phase 3 — MCP oversight surface (admin)

Admin-scoped, read-mostly tools on the diagnostics surface (never content-auth):

- `get_deploy_status` / `get_deploy_history` — read `status.json` / `history.jsonl`.
- `pause_auto_deploy` / `resume_auto_deploy` — write `command.json`.
- `approve_major` — approve a held major release.
- `rollback` — request a rollback to the previous release.

These only read/write the IPC files; the daemon remains the sole holder of Docker
and nginx privileges.

---

## Safety model & the one honest caveat

The "no way to bring the service down" guarantee is enforced in the swap script:
the live container is never stopped before the new one is proven healthy, and any
failure (unhealthy boot, bad nginx config) aborts with the old container still
serving.

**Migrations are the exception that orchestration alone cannot cover.** A new
color runs its startup migration *before* the health gate, against the shared
database. Additive migrations (the normal case) are safe — the old color tolerates
the new schema during the overlap. A **destructive** migration (drop/rename a
column the old code reads) would break the old color too, and auto-rollback of the
*container* cannot un-migrate the *data*. Mitigations:

- The pre-swap **snapshot** is the recoverable backstop (`scripts/restore.sh`).
- The **SemVer major gate** aligns the deploy gate with where breaking changes
  belong, so a destructive migration shipped as a major is held for human
  approval rather than auto-applied.
- During the `0.x` series, keep migrations additive (expand-contract) or tighten
  `DEPLOY_GATE_LEVEL` if a given release is risky.

---

## Open items to confirm on the host (Phase 1)

- Run the one-time nginx upstream edit and confirm `nginx -t` passes.
- Confirm the deployer host user can run `docker` and `nginx -s reload` (today the
  ops commands use `sudo`).
- Decide where the legacy `:8080` compose server is retired once colors are
  trusted (it is harmless to leave running in the meantime).
