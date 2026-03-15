# Chickadee — Deployment Guide

Two deployment paths are documented here:

- **[Docker Compose](#docker-compose-deployment)** — recommended for most deployments; no Swift toolchain on the host required.
- **[VM / systemd](#vm--systemd-deployment)** — native binaries with systemd and nginx; useful when Docker is not available.

---

## Docker Compose Deployment

### Prerequisites

- Docker Engine 24+ and Docker Compose v2 (`docker compose version`)
- A domain name (for HTTPS / production)

### 1. Clone and configure

```bash
git clone https://github.com/JimWallace/Chickadee.git
cd Chickadee
cp .env.example .env
```

Edit `.env`:

| Variable | What to set |
|---|---|
| `RUNNER_SHARED_SECRET` | A strong random secret: `openssl rand -base64 32` |
| `AUTH_MODE` | `local` for username/password; `sso` for OIDC |
| `PUBLIC_BASE_URL` | Your public URL, e.g. `https://chickadee.example.com` |

### 2. Build and start

```bash
docker compose up -d --build
```

The first build compiles both Swift binaries inside the container — this takes
5–15 minutes depending on your machine. Subsequent builds without source changes
use the cached layers and are nearly instant.

Check status:

```bash
docker compose ps
docker compose logs -f server
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

```bash
git pull
docker compose up -d --build
```

The entrypoint script automatically syncs fresh templates and JupyterLite assets
from the new image into the data volume on each restart.

### Scaling the runner

```bash
docker compose up -d --scale runner=4
```

Each runner instance gets a unique worker ID derived from its container ID.

### Data persistence

All persistent data lives in the `chickadee-data` named volume:
- `chickadee.sqlite` — the database
- `submissions/`, `testsetups/`, `results/` — uploaded files

```bash
# Back up the data volume
docker run --rm \
  -v chickadee_chickadee-data:/data \
  -v $(pwd):/backup \
  ubuntu tar czf /backup/chickadee-backup-$(date +%Y%m%d).tar.gz -C /data .
```

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
```

---

## 5. Configure nginx

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
