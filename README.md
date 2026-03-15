<img src="Assets/chickadee-icon-alt.png" alt="Chickadee mascot" width="160" align="right">

# Chickadee

A clean-break rewrite of [Marmoset](https://marmoset.cs.umd.edu), the student code submission and autograding system originally built at the University of Maryland. Written in Swift using [Vapor](https://vapor.codes), targeting macOS and Linux.

---

## What it does

Chickadee accepts student code submissions, runs instructor-defined test suites, and returns structured results. Test suites are plain shell scripts — no language-specific code paths exist in Swift. Adding support for a new language means writing a new shell script; no Swift changes required.

**Students** submit code or notebooks through a web UI, see graded results immediately, and track their submission history per assignment.

**Instructors** create assignments, upload test-setup zips, manage courses and enrollment, and view per-student results and grade exports.

**Admins** manage courses, users, runner configuration, and can trigger retests.

---

## Key features

- **Shell-script test suites.** Any language, any framework — the runner executes `.sh` files and maps the exit code to `pass / fail / error / timeout`. Helper libraries are bundled in the test-setup zip by the instructor.
- **Test dependency trees.** Tests can declare prerequisites (`dependsOn`). If a prerequisite doesn't pass, dependent tests are automatically skipped rather than run against broken code.
- **Four test tiers.** `public` results are shown immediately; `release` results are hidden until the assignment deadline; `secret` results are never shown; `student` results come from student-written tests.
- **In-browser notebook grading.** A full JupyterLite instance is embedded for both student submission and instructor assignment creation — no separate tooling required.
- **Sandboxed execution.** The runner supports OS-level sandboxing (`sandbox-exec` on macOS, `unshare` namespaces on Linux) to isolate untrusted code.
- **Local and SSO auth.** Local username/password for development and self-hosting; full OIDC/SSO (Authorization Code + PKCE) for institutional deployments (Duo, Okta, Entra, etc.). Dual mode runs both simultaneously. Controlled by the `AUTH_MODE` environment variable; roles are auto-assigned from `SSO_ADMIN_USERS` / `SSO_INSTRUCTOR_USERS` allowlists on every login.
- **HMAC-signed runner protocol.** All runner↔server requests are signed with a shared secret. The server auto-generates a diceware passphrase if none is provided.

---

## Architecture

Three Swift targets share a clean dependency boundary:

```
┌───────────────────────────────────────────┐
│             chickadee-server              │
│   REST API (Vapor) + Leaf web UI          │
│   Auth, assignment management,            │
│   submission intake, result storage,      │
│   JupyterLite notebook workflow           │
└──────────────────┬────────────────────────┘
                   │  HTTP (HMAC-signed)
┌──────────────────▼────────────────────────┐
│             chickadee-runner              │
│   Polls for jobs → downloads artifacts    │
│   → ScriptRunner → TestOutcomeCollection  │
└──────────────────┬────────────────────────┘
                   │  subprocess (optionally sandboxed)
        ┌──────────┴──────────┐
        ▼                     ▼
  test_public.sh        test_release.sh
  (instructor-written shell scripts)
```

**Core** — shared models (`TestOutcome`, `TestProperties`, etc.) with no Vapor dependency. Both targets depend on this.

The server and runner can run on the same host or on separate machines. Multiple runner instances can poll the same server concurrently.

---

## Deployment

### Docker (recommended)

No Swift toolchain required on the host. The multi-stage `Dockerfile` compiles both binaries inside a build container and produces a minimal Ubuntu runtime image (~150 MB).

```bash
git clone https://github.com/JimWallace/Chickadee.git
cd Chickadee

cp .env.example .env
# Edit .env: set RUNNER_SHARED_SECRET (required) and any other vars

docker compose up -d --build
```

The first build compiles Swift — expect 5–15 minutes. Subsequent builds with no source changes use the cached layers and are nearly instant.

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

---

## Test script contract

Each test suite is a shell script in the instructor's test-setup zip.

| Exit code | Result |
|-----------|--------|
| `0` | `pass` |
| `1` | `fail` |
| `2` | `error` |
| killed after timeout | `timeout` |

**stdout:** The last non-empty line is parsed as JSON for optional `score` and `shortResult` fields. If it isn't valid JSON, it's used as plain-text `shortResult`.

**stderr:** Captured verbatim as `longResult`.

### Test dependency trees

Tests can declare prerequisites in `test.properties.json`:

```json
{
  "testSuites": [
    { "tier": "public",  "script": "test_build.sh" },
    { "tier": "public",  "script": "test_unit.sh",       "dependsOn": ["test_build.sh"] },
    { "tier": "release", "script": "test_integration.sh", "dependsOn": ["test_build.sh"] }
  ]
}
```

If `test_build.sh` doesn't pass, `test_unit.sh` and `test_integration.sh` are automatically recorded as `fail` with `shortResult: "Skipped: prerequisite 'test_build.sh' did not pass"` — no wasted execution time on a broken build.

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

- `0.y.0` — feature milestones
- `0.y.z` — backward-compatible fixes
- Breaking changes are documented in [`CHANGELOG.md`](CHANGELOG.md)

Release checklist:

```bash
# 1) Update VERSION and CHANGELOG.md
scripts/check-version.sh
swift test

# 2) Tag
git tag -a vX.Y.Z -m "Chickadee vX.Y.Z"
git push origin vX.Y.Z
```
