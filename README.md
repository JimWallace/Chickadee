<img src="Assets/chickadee-icon-alt.png" alt="Chickadee mascot" width="160" align="right">

# Chickadee

A clean-break rewrite of [Marmoset](https://marmoset.cs.umd.edu), the student code submission and autograding system originally built at the University of Maryland. Written in Swift using [Vapor](https://vapor.codes), targeting macOS and Linux.


## Key features

- **Shell-script test suites.** Any language, any framework — the runner executes scripts and maps the exit code to `pass / fail / error / timeout`. Helper libraries are bundled in the test-setup zip by the instructor.
- **Test dependency trees.** Tests can declare prerequisites (`dependsOn`). If a prerequisite doesn't pass, dependent tests are automatically skipped rather than run against broken code.
- **Three test tiers.** `public` results are shown immediately; `release` results are hidden until the assignment deadline; `secret` results are never shown.
- **In-browser notebook grading.** A full JupyterLite instance is embedded for both student submission and instructor assignment creation — no separate tooling required.
- **Local and SSO auth.** Local username/password for development and self-hosting; full OIDC/SSO (Authorization Code + PKCE) for institutional deployments (Duo, Okta, Entra, etc.). Dual mode runs both simultaneously. Controlled by the `AUTH_MODE` environment variable; roles are auto-assigned from `SSO_ADMIN_USERS` / `SSO_INSTRUCTOR_USERS` allowlists on every login.
- **HMAC-signed runner protocol.** All runner↔server requests are signed with a shared secret. The server auto-generates a diceware passphrase if none is provided.

---

## Deployment

### Docker (recommended)

No Swift toolchain required on the host. The multi-stage `Dockerfile` compiles both binaries inside a build container and produces a minimal Ubuntu runtime image (~150 MB).

```bash
git clone https://github.com/JimWallace/Chickadee.git
cd Chickadee

cp .env.example .env
# Edit .env for auth / URL settings as needed

docker compose up -d --build
```

The first build compiles Swift — expect 5–15 minutes. Subsequent builds with no source changes use the cached layers and are nearly instant.

In Docker Compose, the server auto-generates a three-word `.worker-secret` on
the shared data volume and the runner reads that file automatically. You can
still set `RUNNER_SHARED_SECRET` explicitly in `.env` if you want a fixed secret.

```bash
# Verify
curl http://localhost:8080/health

# View logs
docker compose logs -f server

# Scale to more runner workers
docker compose up -d --scale runner=4

# Update after a git pull
docker compose up -d --build
```

Each scaled Docker runner now derives a unique default worker ID from its
container hostname. If you run runners outside Docker, make sure each one still
uses a distinct `--worker-id`.

For HTTPS, nginx, and production configuration see **[deploy/README.md](deploy/README.md)**.

### VM / systemd

Install Swift via [`swiftly`](https://swift.org/install/linux), build release binaries, and manage them as systemd services with nginx as a reverse proxy. See **[deploy/README.md](deploy/README.md)** for step-by-step instructions, service files, and certbot setup.

---

## Local development

Requires Swift 6 ([swift.org](https://swift.org/download)) and Xcode 16+ on macOS.

```bash
swift build
swift test
```

Run the server:

```bash
# AUTH_MODE defaults to SSO; override for local dev:
AUTH_MODE=local ENABLE_NON_SSO_AUTH_MODES=true \
  swift run chickadee-server serve --port 8080 --worker-secret dev-secret
```

Run the runner against the local server:

```bash
RUNNER_SHARED_SECRET=dev-secret \
  swift run chickadee-runner \
    --api-base-url http://localhost:8080 \
    --worker-id    local-runner \
    --max-jobs     2
```

The admin dashboard also supports a **local runner autostart** toggle that spawns a runner subprocess automatically — useful for development without a second terminal.

For backend observability details, retention settings, and the protected
`/admin/metrics` JSON endpoint, see **[docs/operational-diagnostics.md](docs/operational-diagnostics.md)**.

For backend runner capability matching and assignment requirement rollout
guidance, see **[docs/runner-capability-profiles.md](docs/runner-capability-profiles.md)**.

---

## JupyterLite

`Public/jupyterlite/` is generated output and is checked in. Source-of-truth config lives in `Tools/jupyterlite/`. Rebuild only when updating kernel versions or config:

```bash
scripts/setup-jupyterlite.sh
scripts/build-jupyterlite.sh
```

---

## Versioning

Chickadee follows Semantic Versioning in the `0.y.z` phase. Current version: see [`VERSION`](VERSION).
