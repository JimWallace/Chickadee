# Chickadee — Deployment Guide

Two deployment paths are documented here:

- **[Docker Compose](#docker-compose-deployment)** — recommended for most deployments; no Swift toolchain on the host required.
- **[VM / systemd](#vm--systemd-deployment)** — native binaries with systemd and nginx; useful when Docker is not available.

---

## Docker Compose Deployment

### Prerequisites

- Docker Engine 24+ and Docker Compose v2 (`docker compose version`)
- A domain name (for HTTPS / production)

> **Language runtimes:** The Docker image includes Python 3 (with numpy, pandas,
> scipy, matplotlib) and R base out of the box. If your test scripts require
> additional packages, create a `Dockerfile.local` that extends the image:
> ```dockerfile
> FROM ghcr.io/jimwallace/chickadee:latest
> USER root
> RUN pip3 install --no-cache-dir mypackage
> RUN Rscript -e "install.packages('tidyverse', repos='https://cloud.r-project.org')"
> USER chickadee
> ```
> Then set `build: { context: ., dockerfile: Dockerfile.local }` on both the
> `server` and `runner` services in `docker-compose.yml`.

### 1. Clone and configure

```bash
git clone https://github.com/JimWallace/Chickadee.git
cd Chickadee
cp .env.example .env
chmod 600 .env   # secrets file — restrict to owner only
```

Edit `.env`:

| Variable | What to set |
|---|---|
| `RUNNER_SHARED_SECRET` | Optional. Leave unset to use Chickadee's auto-generated three-word `.worker-secret`, or set a fixed secret explicitly (for example `openssl rand -base64 32`). |
| `DATABASE_BACKEND` | Optional. Leave unset or set to `sqlite` to keep the current default backend. Set to `postgres` to use PostgreSQL. |
| `SQLITE_PATH` | Optional. Path to the SQLite file. Defaults to `/data/chickadee.sqlite` in the containerized deployment. |
| `DATABASE_HOST` / `DATABASE_PORT` / `DATABASE_NAME` / `DATABASE_USER` / `DATABASE_PASSWORD` | Required only when `DATABASE_BACKEND=postgres`. |
| `AUTH_MODE` | `local` for username/password; `sso` for OIDC |
| `PUBLIC_BASE_URL` | Your public URL, e.g. `https://chickadee.example.com` |

### Database backend selection

SQLite remains the default backend for existing deployments. If you do nothing,
Chickadee will continue to use the single-file SQLite database at
`/data/chickadee.sqlite`.

To opt into PostgreSQL, set:

```env
DATABASE_BACKEND=postgres
DATABASE_HOST=db
DATABASE_PORT=5432
DATABASE_NAME=chickadee
DATABASE_USER=chickadee
DATABASE_PASSWORD=change-me
```

If `DATABASE_BACKEND=postgres` is selected and any required setting is missing,
the server now fails fast at startup with a clear configuration error.

### 2. Pull and start

```bash
docker compose pull   # downloads the pre-built image from GitHub Container Registry
docker compose up -d
```

The image is built automatically by GitHub Actions on every push to `main` — no
Swift toolchain is required on the server. The first pull downloads ~500 MB;
subsequent pulls only fetch changed layers.

By default, the Compose runner reads `/data/.worker-secret` from the shared
named volume, so the server's auto-generated three-word secret works without
copying it into `.env`. If you set `RUNNER_SHARED_SECRET`, that explicit value
still overrides the generated file.

### Optional PostgreSQL service example

The default deployment path stays on SQLite. If you want to prepare a Postgres
deployment without changing the default path, add a service like this to your
Compose file and set the database env vars above on the `server` service:

```yaml
services:
  db:
    image: postgres:16
    restart: unless-stopped
    environment:
      POSTGRES_DB: chickadee
      POSTGRES_USER: chickadee
      POSTGRES_PASSWORD: change-me
    volumes:
      - chickadee-postgres:/var/lib/postgresql/data
```

This PR only makes backend selection configurable. It does not migrate any
existing SQLite data into PostgreSQL for you.

Check status:

```bash
docker compose ps
docker compose logs -f server
docker compose logs -f runner
```

### 3. Verify

```bash
curl http://localhost:8080/health
# → {"status":"ok","version":"0.3.0","db":"ok","runner":{"recentActivity":false}}
```

Navigate to `http://localhost:8080` and log in to create your first admin account.

### 4. Add HTTPS with Let's Encrypt (production)

```bash
# Install certbot on the host
sudo apt install certbot

# Stop nginx momentarily and issue the certificate
docker compose stop nginx
sudo certbot certonly --standalone -d chickadee.example.com
docker compose start nginx
```

Then in `deploy/nginx-docker.conf`:
1. Uncomment the HTTPS server block and replace the domain name.
2. Add `return 301 https://$host$request_uri;` to the HTTP server block.

In `docker-compose.yml`:
- Uncomment the `nginx` service.
- Remove the `"8080:8080"` port mapping from the `server` service.

In `.env`:
```
PUBLIC_BASE_URL=https://chickadee.example.com
ENFORCE_HTTPS=true
SESSION_COOKIE_SECURE=true
```

Reload:
```bash
docker compose up -d
```

### 5. Updating

Use the deploy script from the repo root — it backs up the SQLite database when
present, pulls the
new image, restarts services, and confirms the health check passes:

```bash
scripts/server-deploy.sh
```

The entrypoint script automatically syncs fresh templates and JupyterLite assets
from the new image into the data volume on each restart. Fluent schema migrations
also run automatically on startup.

> **Note (v0.4.46+):** Sessions are now persisted in the database (`_fluent_sessions`
> table). The migration runs automatically on startup. All existing users will be
> logged out once when this version is first deployed.

**Rollback** to a specific build (replace the SHA with one from the
[GHCR package page](https://github.com/JimWallace/Chickadee/pkgs/container/chickadee)
or the Actions run summary):

```bash
CHICKADEE_IMAGE=ghcr.io/jimwallace/chickadee:sha-abc1234 scripts/server-deploy.sh
```

### CI/CD pipeline

Every push to `main` triggers `.github/workflows/docker-build.yml`, which:

1. Builds the Docker image using BuildKit (Swift dependency layer is cached,
   so incremental builds take ~5–7 minutes)
2. Pushes two tags to GitHub Container Registry:
   - `ghcr.io/jimwallace/chickadee:latest` — always the current `main` build
   - `ghcr.io/jimwallace/chickadee:sha-<commit>` — immutable, used for rollback
3. On version tags (`v0.x.y`): also pushes `ghcr.io/jimwallace/chickadee:v0.x.y`

Pull requests build the image but do **not** push, catching build failures
before they reach `main`.

Browse available image tags at:
https://github.com/JimWallace/Chickadee/pkgs/container/chickadee

### Scaling the runner

```bash
docker compose up -d --scale runner=4
```

Scaled Docker runners should each have a unique worker ID. The bundled Compose
file defaults to `runner-${HOSTNAME}` so replicas do not conflict with each
other. For non-Docker deployments, assign a distinct `--worker-id` per runner.

Each runner instance gets a unique worker ID derived from its container ID.

During an upgrade or server restart, existing runner containers should reconnect
on their own. If the API stays unavailable longer than the bounded retry window
for downloads or result uploads, the active job can still fail cleanly and will
be visible in the structured runner logs.

### Observability and operations

Backend-only observability is built in:

- Structured server logs cover submission enqueue, runner polling/heartbeat,
  assignment, result receipt, and job finalisation.
- Structured runner logs cover startup, config, poll cycles, job acceptance,
  per-test execution, result submission, errors, timeouts, and shutdown.
- SQLite now stores `job_execution_metrics` and `runner_snapshots`.
- Authenticated admins can query `GET /admin/metrics` for queue depth, in-flight
  jobs, active runners, per-runner load, and recent timing/status summaries.

Useful commands:

```bash
docker compose logs -f server | jq -R 'fromjson?'
docker compose logs -f runner | jq -R 'fromjson?'
curl -H "Cookie: <admin-session-cookie>" http://localhost:8080/admin/metrics | jq
```

Retention knobs:

- `JOB_METRIC_RETENTION_DAYS` (default `30`)
- `RUNNER_SNAPSHOT_RETENTION_DAYS` (default `14`)
- `RUNNER_ACTIVE_WINDOW_SECONDS` (default `120`)
- `METRICS_RECENT_WINDOW_HOURS` (default `24`)
- `OBSERVABILITY_PRUNE_INTERVAL_HOURS` (default `24`)

Runner capability matching is also available:

- runners advertise platform, architecture, language versions, and named
  capabilities on poll and heartbeat
- assignments can declare optional backend-only requirement rows in
  `assignment_requirements`
- the server only assigns jobs to compatible runners

Capability discovery knob:

- `RUNNER_CAPABILITY_DISCOVERY_ENABLED` (default enabled)

Runner interruption resilience knobs:

- `RUNNER_NETWORK_RETRY_ENABLED` (default enabled)
- `RUNNER_DOWNLOAD_RETRY_MAX_ATTEMPTS` (default `6`)
- `RUNNER_RESULT_UPLOAD_RETRY_MAX_ATTEMPTS` (default `8`)
- `RUNNER_HEARTBEAT_RETRY_MAX_ATTEMPTS` (default `4`)
- `RUNNER_RETRY_BASE_DELAY_MS` (default `1000`)
- `RUNNER_RETRY_MAX_DELAY_MS` (default `30000`)

Short outage behavior:

- poll requests keep retrying until the server is back
- heartbeats retry within a bounded window, then resume on the next interval
- submission downloads, test-setup downloads, and result uploads retry with
  exponential backoff before failing the active job
- runner logs emit `server_connection_lost`, `network_retry_scheduled`,
  `heartbeat_retry_scheduled`, and `server_connection_restored`

See `docs/runner-capability-profiles.md` for rollout notes and troubleshooting.

### Data persistence

All persistent data lives in the `chickadee-data` named volume:
- `chickadee.sqlite` — the default SQLite database
- `submissions/`, `testsetups/`, `results/` — uploaded files

If you switch to PostgreSQL, the server data volume still stores uploaded files
and secrets, but the database itself lives in the Postgres data volume instead.

```bash
# Back up the data volume
docker run --rm \
  -v chickadee_chickadee-data:/data \
  -v $(pwd):/backup \
  ubuntu tar czf /backup/chickadee-backup-$(date +%Y%m%d).tar.gz -C /data .
```

### Snapshots and rollback

`scripts/snapshot.sh` and `scripts/restore.sh` provide point-in-time snapshot
and restore for **PostgreSQL deployments** (Docker Compose). Each snapshot
captures the database (`pg_dump -Fc`) plus the on-disk artifacts that the
database rows reference (`testsetups/`, `submissions/`, `results/`,
`.worker-secret`, `.local-runner-autostart`) into a timestamped directory
under `backups/snapshot-<TS>[-<label>]/`. A `manifest.json` is written last
so a partial snapshot can be detected and refused.

> **SQLite deployments are not supported by these scripts** — the existing
> `scripts/server-deploy.sh` already tars the entire data volume (including
> `chickadee.sqlite`) before every deploy, which is sufficient.

#### Taking a snapshot

```bash
scripts/snapshot.sh                       # label defaults to "manual"
scripts/snapshot.sh --label pre-appscan   # any [A-Za-z0-9._-]+ identifier
```

The script:
- verifies `DATABASE_BACKEND=postgres` and that the `db` service is
  accepting connections,
- dumps Postgres via `docker compose exec db pg_dump -Fc`,
- archives the artifact paths from the `chickadee-data` volume,
- writes `manifest.json` last (atomic-publish trick),
- prunes `backups/snapshot-*` directories older than **7 days**.

The server keeps running. Postgres dumps are consistent at a single
transaction snapshot.

#### Restoring a snapshot

```bash
scripts/restore.sh backups/snapshot-20260516-030000-scheduled
```

The script stops `server` and `runner` (leaving `db` running),
`pg_restore --clean --if-exists` over the existing database, wipes and
re-extracts the artifact paths from the snapshot's `data.tar.gz`, then
restarts the services and waits for `/health`. Interactive: type `RESTORE`
to confirm. Pass `--yes` to skip the prompt.

If the snapshot's chickadee version differs from the current `VERSION`,
the script warns and requires `--yes` to proceed — Fluent migrations will
run on startup, which is fine going forward across additive migrations but
**not** safe across a destructive migration.

#### AppScan weekend workflow

Before handing off admin credentials to Security:

```bash
echo "SCAN_MODE=true" >> .env
docker compose up -d server runner          # picks up the env change
scripts/snapshot.sh --label pre-appscan
```

After the scan completes:

```bash
scripts/snapshot.sh --label post-appscan    # forensics — keep the
                                            # post-scan state for review
scripts/restore.sh backups/snapshot-*-pre-appscan
# edit .env: remove SCAN_MODE=true
docker compose up -d server runner
```

`SCAN_MODE=true` (v0.4.167) already blocks the obvious destructive endpoints
during the scan; the snapshot is a safety net if anything slips through.

#### Scheduled snapshots (cron)

Once installed and verified, add a daily snapshot to root's crontab on the
production host:

```cron
# /etc/crontab or `sudo crontab -e`
0 3 * * * cd /opt/chickadee && scripts/snapshot.sh --label scheduled >> /var/log/chickadee-snapshot.log 2>&1
```

3am local time, label `scheduled` so they're easy to distinguish from
on-demand snapshots. The 7-day prune inside `snapshot.sh` keeps `backups/`
bounded.

#### Refreshing a staging server from prod

The snapshot bundle is portable. To sync a staging server from a recent
prod state:

```bash
# On prod
scripts/snapshot.sh --label for-staging

# Copy to staging
rsync -av backups/snapshot-*-for-staging/ \
  staging-host:/opt/chickadee/backups/snapshot-from-prod/

# On staging
scripts/restore.sh backups/snapshot-from-prod \
  --regenerate-secrets --scrub-pii --yes
```

- `--regenerate-secrets` deletes `.worker-secret` so the staging server
  writes a fresh runner HMAC secret on next boot. **Always pass this when
  copying across environments** — without it, a staging runner could
  authenticate against prod (or vice versa).
- `--scrub-pii` anonymises identity columns on `users` rows where
  `role='student'` (username, email, display_name, preferred_name,
  user_id, student_id, external_subject, brightspace_user_id). Admin and
  instructor rows are preserved so existing logins still work.
- **`.env` is NOT in the snapshot.** Staging keeps its own
  `PUBLIC_BASE_URL`, OIDC callback URL, BrightSpace credentials, etc.
  Copy `.env` separately if you want to clone those too — usually you
  don't.

**Known PII-scrub gaps** (acknowledge before broadening staging access):
- Submission zip contents (student code) are NOT scrubbed.
- Submission filenames are NOT scrubbed.
- Free-text fields on `submission_diagnostics` and similar tables are NOT
  scrubbed.

---

## VM / systemd Deployment

This guide covers a standard Linux VM deployment: native Swift binaries, systemd
service management, and nginx as the reverse proxy.

---

## Prerequisites

- Ubuntu 22.04 / 24.04 (or equivalent Linux distro)
- Swift 6.0+ installed ([swift.org/download](https://swift.org/download/))
- nginx installed (`apt install nginx`)
- Your OIDC credentials from your identity provider (e.g. Duo, Okta, Entra)
- Python 3 and R for the runner (`apt install python3 python3-pip python3-numpy python3-pandas python3-scipy python3-matplotlib r-base`). Install additional packages as needed for your courses.

---

## 1. Build

On your development machine (or on the VM if Swift is installed there):

```bash
swift build -c release
```

This produces two binaries:
- `.build/release/chickadee-server`
- `.build/release/chickadee-runner`

---

## 2. Copy Files to the VM

```bash
# Create the deploy directory
ssh your-vm "sudo mkdir -p /opt/chickadee && sudo useradd -r -s /bin/false chickadee && sudo chown chickadee:chickadee /opt/chickadee"

# Copy binaries and assets
rsync -av \
  .build/release/chickadee-server \
  .build/release/chickadee-runner \
  Public/ Resources/ \
  your-vm:/opt/chickadee/
```

The `Public/` directory contains JupyterLite and other static assets.
The `Resources/` directory contains Leaf templates, wordlists, and other server assets.

---

## 3. Configure Environment

```bash
# On the VM:
cp /opt/chickadee/deploy/.env.example /opt/chickadee/.env
nano /opt/chickadee/.env   # fill in OIDC credentials, PUBLIC_BASE_URL, etc.
sudo chown chickadee:chickadee /opt/chickadee/.env
sudo chmod 640 /opt/chickadee/.env
```

Key values to set:
- `PUBLIC_BASE_URL` — your VM's public URL (e.g. `https://chickadee.cs.example.com`)
- `OIDC_AUTH_SERVER`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` — from your IdP
- `SSO_ADMIN_USERS` — your username, so the first login gives you admin access

---

## 4. Install systemd Services

```bash
sudo cp /opt/chickadee/deploy/chickadee-server.service /etc/systemd/system/
sudo cp /opt/chickadee/deploy/chickadee-runner.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable chickadee-server chickadee-runner
sudo systemctl start chickadee-server chickadee-runner
```

Check status:
```bash
sudo systemctl status chickadee-server
sudo systemctl status chickadee-runner
sudo journalctl -u chickadee-server -f   # live logs
sudo journalctl -u chickadee-runner -f
```

---

## 5. Configure nginx

## Operational checks

Quick checks once the services are up:

```bash
curl http://127.0.0.1:8080/health
curl -H "Cookie: <admin-session-cookie>" http://127.0.0.1:8080/admin/metrics | jq
```

Questions this data now answers:

- Add more runners:
  Watch for persistent queue depth, increasing queue wait, and runners at or
  near zero available capacity.
- Jobs timing out more than usual:
  Check recent `timeout` counts in `/admin/metrics`, then confirm with
  `job_finalised` and runner `timeout` logs.
- Which runner is overloaded:
  Compare each runner's `activeJobs`, `availableCapacity`, and recent heartbeat
  cadence.
- Mostly test failures or infrastructure errors:
  Use `job_execution_metrics.final_status` for the broad split, then inspect
  `test_result_summary` and `local_execution_error` logs for detail.

```bash
sudo cp /opt/chickadee/deploy/nginx.conf /etc/nginx/sites-available/chickadee
sudo ln -s /etc/nginx/sites-available/chickadee /etc/nginx/sites-enabled/chickadee
# Edit the file — replace "your-vm.example.com" with your actual domain
sudo nano /etc/nginx/sites-available/chickadee
sudo nginx -t && sudo systemctl reload nginx
```

### HTTPS (recommended)

```bash
sudo apt install certbot python3-certbot-nginx
sudo certbot --nginx -d your-vm.example.com
```

After certbot runs, update your `.env`:
```bash
ENFORCE_HTTPS=true
SESSION_COOKIE_SECURE=true
PUBLIC_BASE_URL=https://your-vm.example.com
```

Then restart the server: `sudo systemctl restart chickadee-server`

---

## 6. First Login

1. Navigate to `https://your-vm.example.com`
2. You'll be redirected to your IdP for SSO login
3. Your username (listed in `SSO_ADMIN_USERS`) will be promoted to admin on first login
4. Go to `/admin` to create courses, manage users, and configure the runner

---

## 7. Health Check

```bash
curl https://your-vm.example.com/health
# → {"status":"ok","version":"0.3.0","db":"ok","runner":{"recentActivity":false}}
```

Returns HTTP 503 if the database is unreachable.

---

## Updating

```bash
# On dev machine: build and copy new binaries
swift build -c release
rsync -av .build/release/chickadee-server .build/release/chickadee-runner your-vm:/opt/chickadee/

# On the VM: restart services
sudo systemctl restart chickadee-server chickadee-runner
```

If you also changed templates or static assets, rsync `Public/` and `Resources/` as well.

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| 502 Bad Gateway | `systemctl status chickadee-server` — is it running? |
| SSO redirect loop | Verify `OIDC_CALLBACK` matches the redirect URI registered with your IdP |
| Students not auto-enrolled | Make sure exactly one non-archived course exists in `/admin/courses` |
| Runner not picking up jobs | Check `journalctl -u chickadee-runner`; verify `RUNNER_SHARED_SECRET` matches `.worker-secret` |
| JupyterLite broken | Ensure nginx passes `Cross-Origin-Opener-Policy` / `Cross-Origin-Embedder-Policy` headers |
