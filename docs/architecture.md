# Chickadee — Architecture

## Overview

Chickadee is a student code submission and autograding system written in Swift
using the Vapor framework. It replaces Marmoset (University of Maryland, Java)
with a clean-break rewrite targeting macOS and Linux.

The system has three responsibilities:

1. **Accept** student submissions (files or notebooks) via a web UI or API.
2. **Grade** them by running instructor-authored test scripts in an isolated
   subprocess.
3. **Return** structured results to the student and instructor.

---

## Three-Target Architecture

```
┌─────────────────────────────────────────────────────┐
│                      Core                           │
│  Codable/Sendable models shared by both targets.    │
│  No Vapor dependency.                               │
│  TestOutcome · TestOutcomeCollection · Job          │
│  TestProperties · CourseBundleManifest · …          │
└────────────────────┬────────────────────────────────┘
                     │ (imported by both)
          ┌──────────┴───────────┐
          ▼                      ▼
┌──────────────────┐    ┌─────────────────────┐
│ chickadee-server │    │  chickadee-runner   │
│ (Vapor app)      │    │  (daemon process)   │
│                  │    │                     │
│ REST API         │◄───┤ polls /worker/      │
│ Leaf web UI      │    │ request             │
│ Auth / sessions  │───►│ receives Job        │
│ DB (Fluent)      │    │ runs shell scripts  │
│ File storage     │◄───┤ POST /worker/       │
│ Observability    │    │ results             │
└──────────────────┘    └─────────────────────┘
```

`chickadee-server` and `chickadee-runner` communicate over HTTP. The runner
never calls any Swift API from the server — the boundary is the wire protocol.
This means the runner can be deployed on a completely different host or inside
a Docker container with no shared filesystem.

### Source layout

```
Sources/
  Core/                     Shared models (no Vapor)
    Models/                 TestOutcome, TestTier, TestStatus, …
    CourseBundleManifest.swift
    Job.swift
    TestProperties.swift
    RunnerResult.swift
    …
  APIServer/                chickadee-server target
    Routes/                 REST + web route handlers
      Web/                  Leaf-rendered instructor/admin/student pages
    Middleware/             Auth, CSRF, HTTPS redirect, security headers
    Models/                 Fluent model classes (DB-mapped)
    Migrations/             Ordered migration chain
    Auth/                   Local auth, OIDC/SSO
    Diagnostics/            OperationalDiagnosticsService
    Utilities/              ZipArchiver, ManifestValidation, …
  Worker/                   chickadee-runner target
    RunnerDaemon.swift      WorkerDaemon actor + WorkerCommand entry point
    ScriptRunner.swift      ScriptRunner protocol
    SandboxedScriptRunner.swift
    SubmissionNormalizer.swift
    NotebookExtractor.swift
    TestRuntimeSources.swift  Embedded Python + R helper libraries
    RunnerNetworkResilience.swift
    …
```

---

## The Grading Pipeline

```
Student browser
      │  POST /api/v1/submissions  (multipart file upload)
      ▼
SubmissionRoutes
  • Validate course enrollment
  • Store submission zip/file on disk
  • Create APISubmission row (status = "pending")
      │
      ▼
WorkerJobRoutes  ←────── runner polls POST /worker/request ──────────────┐
  • SELECT pending submission                                              │
  • Compatibility check (RunnerCapabilityProfile vs AssignmentRequirements)│
  • WorkerClaimQueue actor serialises concurrent claims                   │
  • UPDATE status = "assigned", workerID = <runner>                       │
  • Return Job to runner ────────────────────────────────────────────────►│
                                                                          │
                                                          chickadee-runner │
                                                            ┌─────────────┘
                                                            │
                                                            ▼
                                                      JobPoller.requestJob()
                                                            │
                                                            ▼
                                                      WorkerDaemon.process()
                                                        • Download submission zip
                                                          (GET /worker/artifacts/:id)
                                                        • Download test setup zip
                                                          (GET /api/v1/testsetups/:id/download)
                                                        • SubmissionNormalizer (Python jobs)
                                                        • extractNotebooksToCode (ipynb → .py/.R)
                                                        • Write test_runtime.py / test_runtime.R
                                                        • Optional: run make
                                                        • Run each test script with ScriptRunner
                                                        • Assemble TestOutcomeCollection
                                                            │
                                                            ▼
                                                      Reporter.report()
                                                        POST /worker/results
                                                            │
                                                            ▼
ResultRoutes
  • Persist TestOutcomeCollection as APIResult row
  • UPDATE APISubmission status = "complete"
  • Record diagnostics (OperationalDiagnosticsService)
      │
      ▼
Student browser
  GET /results/:id  →  Leaf-rendered result view
```

---

## Python / Notebook Submission Normalization

Added in v0.4.30. Before the test scripts run, the runner preprocesses Python
submissions through a normalization pipeline:

```
Submission file(s)
      │
      ▼
MimeTypeDetector
  Uses `file --mime-type` to detect actual content type
  (ignores uploaded filename extension)
      │
      ├─ plain Python script → copy to workspace as-is
      │
      └─ Jupyter notebook JSON → NotebookExtractor
            • Validates JSON structure
            • Extracts code cells in order
            • Writes <stem>.py to workspace
            • Warns if no code cells
      │
      ▼
SubmissionNormalizer
  • Emits NormalizationResult.warnings (surfaced in student results)
  • Writes .chickadee_student_module hint file
  • Handles extension/content mismatches
  • Backward-compat filename copy when requiredFiles has exactly one .py
```

`extractNotebooksToCode` (in `NotebookExtractor.swift`) handles the instructor
side: it converts `.ipynb` files in the test setup directory to `.py` or `.R`
before the test scripts run. This is separate from student submission
normalization and runs for all jobs, not just Python ones.

The shell scripts themselves remain language-agnostic. Normalization is a
submission-format concern, not a grading concern.

---

## Authentication & Roles

### Roles

Three roles in ascending privilege order: `student` < `instructor` < `admin`.
Admin implies instructor. Role is stored on `APIUser` and enforced by
`RoleMiddleware` at the route group level (see `routes.swift`).

### Auth modes

`AUTH_MODE` env var selects the active mode:

| Mode | Behaviour |
|------|-----------|
| `.local` | Username + bcrypt password stored in `users` table |
| `.sso` | OIDC Authorization Code + PKCE against an external IdP |
| `.dual` | Both active simultaneously; SSO is the primary path |

SSO implementation lives in `SSOAuthRoutes.swift` and `OIDCConfiguration.swift`.
The discovery document and JWKS are fetched from `OIDC_AUTH_SERVER` at startup.
Role assignment uses `SSO_ADMIN_USERS` / `SSO_INSTRUCTOR_USERS` allowlists
(comma-separated, checked against JWT claims on every login).

`ENABLE_NON_SSO_AUTH_MODES` controls whether `.local` and `.dual` are available
(useful when the deployment policy mandates SSO-only).

### Session management

Vapor's `SessionAuthenticator` — sessions are in-memory by default (swap to
`.fluent` for multi-process / load-balanced deployments). Session cookie is
`HttpOnly; SameSite=Lax`. The `Secure` flag is set automatically when
`PUBLIC_BASE_URL` is `https://` or auth mode is non-local.

### HTTPS enforcement

`AppSecurityConfiguration` reads `ENFORCE_HTTPS`, `PUBLIC_BASE_URL`,
`TRUST_X_FORWARDED_PROTO`, and `SESSION_COOKIE_SECURE`.
`HTTPSRedirectMiddleware` handles redirects and respects `X-Forwarded-Proto`
from reverse proxies.

---

## Job Lifecycle & Concurrency

### WorkerClaimQueue actor

Concurrent runner instances poll `/worker/request` simultaneously. To prevent
two runners from claiming the same job, all claims are serialised through
`WorkerClaimQueue` — a Swift actor eagerly initialised at server startup.

```swift
actor WorkerClaimQueue {
    func claimNextJob(for runnerID: String, ...) async throws -> Job? { … }
}
```

The actor executes claim transactions one at a time. Each transaction does a
`SELECT … FOR UPDATE`-equivalent (SQLite WAL + transaction) to atomically
find a pending job and mark it assigned.

### WorkerDaemon concurrency

The runner side uses structured concurrency: `WorkerDaemon` spawns one
`Task` per slot (up to `--max-jobs`). Each slot runs its own poll/execute loop
independently. `activeJobs` is a mutable `Int` on the actor, incremented at
job start and decremented in a `defer` block at job end.

### Timeout handling

Script timeouts use a structured child `Task` that sleeps for
`timeLimitSeconds` and then sends `SIGKILL` to the process group. This keeps
timeout logic within Swift's cooperative concurrency model rather than using
`DispatchQueue`.

---

## Test Script Contract

Each test suite is a `.sh` file at the root of the instructor's test setup zip.

| Exit code | Meaning |
|-----------|---------|
| 0 | pass |
| 1 | fail |
| 2 | error |
| killed after timeout | timeout |

**stdout:** Everything is ignored except the last non-empty line, which is
parsed as optional JSON `{ "score": 0.75, "shortResult": "3/4 passed" }`.
If not valid JSON, the line is used as plain-text `shortResult`. If stdout is
empty, `shortResult` is synthesized from the exit code.

**stderr:** Captured verbatim as `longResult` (nil if empty).

Test dependencies can be declared in `TestProperties.testSuites[].dependsOn`.
If a prerequisite did not pass, dependents are automatically recorded as `fail`
with a "Skipped: prerequisite '…' did not pass" message. Both the server-side
runner and the browser-side Pyodide runner implement this.

---

## Runner Sandboxing

`ScriptRunner` is a protocol with two implementations:

```swift
protocol ScriptRunner: Sendable {
    func run(script: URL, in directory: URL, timeLimit: Duration) async throws -> ScriptOutput
}

struct UnsandboxedScriptRunner: ScriptRunner { … }   // default in development
struct SandboxedScriptRunner: ScriptRunner { … }     // --sandbox flag
```

`SandboxedScriptRunner` uses platform-specific primitives:
- **macOS:** `sandbox-exec` with a generated profile
- **Linux:** `unshare --user --net` to drop privileges and isolate the network
  namespace

The sandbox boundary is at the subprocess level. Swift never imports a JVM,
Python interpreter, or any language runtime — all language execution goes
through `Foundation.Process`.

---

## Runner Capability Matching

Runners advertise a `RunnerCapabilityProfile` on every poll (platform,
architecture, language versions, named capabilities). Assignments can declare
an `AssignmentRequirementSpec`. The server's `CompatibilityMatcher` checks the
runner profile against the requirement before assigning a job.

Jobs with no requirement run on any runner. Jobs with requirements are only
assigned to a compatible runner; if none is available the job stays pending.

See [`runner-capability-profiles.md`](runner-capability-profiles.md) for the
full matching rules, rollout details, and troubleshooting guide.

---

## Worker HMAC Authentication

All runner↔server requests are signed with HMAC-SHA256:

```
X-Worker-Timestamp: <unix seconds>
X-Worker-Nonce:     <random UUID>
X-Worker-Signature: HMAC-SHA256(secret, "timestamp=…&nonce=…&body_sha256=…")
X-Worker-Body-SHA256: SHA256(request body)
```

`WorkerHMACAuthMiddleware` validates each request. The shared secret is
auto-generated from a three-word EFF diceware passphrase on first startup and
persisted to `.worker-secret`. The runner reads it from `RUNNER_SHARED_SECRET`
(env var or `.worker-secret` file). The admin dashboard can rotate the secret
at runtime.

---

## Database & Migrations

`DatabaseConfiguration` selects the backend from `DATABASE_URL`:
- `postgres://…` → Fluent PostgreSQL driver
- absent / `sqlite://…` → Fluent SQLite driver (default for development)

SQLite deployments enable WAL journaling and foreign key enforcement at startup.

Migrations are registered in order in `APIServerApp.swift`. All migrations are
additive (new columns or tables); no migration drops data. Migration names
follow the pattern `Create<ModelName>` for canonical baseline tables and
`Add<Feature>` for subsequent additions.

Current migration count: 17 (as of v0.4.36).

---

## Observability

Chickadee records durable metrics in three tables:

| Table | Purpose |
|-------|---------|
| `job_execution_metrics` | Per-job timing and outcome counters |
| `runner_snapshots` | Runner heartbeat liveness data |
| `request_metrics` | Server-side HTTP request timing |

`OperationalDiagnosticsService` centralises all writes. Write failures are
non-fatal and logged as warnings — observability must never block grading.

The `GET /admin/metrics` endpoint (admin-only) exposes live queue depth,
runner load, rolling averages, and compatibility counters.

See [`operational-diagnostics.md`](operational-diagnostics.md) for the full
field reference, structured log event catalogue, and ops runbook.

---

## JupyterLite

A full JupyterLite instance lives at `Public/jupyterlite/`. It powers two
workflows:

1. **Student submission:** students edit their notebook in-browser and submit
   via JupyterLite's "Upload" action.
2. **Instructor authoring:** instructors create and validate assignments without
   leaving the browser (in-browser edit/save/validate cycle added in Phase 8).

The embedded content is generated output checked into the repo. Rebuild only
when updating kernel versions:

```bash
scripts/setup-jupyterlite.sh
scripts/build-jupyterlite.sh
```

`JupyterLiteContentsRoutes` serves the JupyterLite contents API. It maps
JupyterLite file paths to the server's test setup storage so the notebook
editor reads and writes the canonical `.ipynb` files directly.

---

## Deployment

### Docker Compose (recommended)

Multi-stage `Dockerfile` compiles both binaries with `--static-swift-stdlib`
so no Swift toolchain is needed on the host. `docker-compose.yml` runs three
services:

| Service | Role |
|---------|------|
| `server` | `chickadee-server` — the Vapor app |
| `runner` | `chickadee-runner` — the grading daemon |
| `nginx` | Reverse proxy, TLS termination |

Persistent data lives in named Docker volumes. `deploy/docker-entrypoint.sh`
syncs static assets from the image into the data volume on each startup so
template and JupyterLite changes are picked up automatically on redeploy.

### VM / systemd

Two `systemd` units: `chickadee-server.service` and
`chickadee-runner.service`. See `deploy/README.md` for unit files and
environment variable reference.

### Local development

1. `swift run chickadee-server` — starts the server on `:8080`
2. The server can auto-spawn a local runner if `.local-runner-autostart` exists
   (or is toggled in the admin dashboard). This convenience is disabled in
   production.

---

## Configuration

Every server-side environment variable read flows through `AppConfig`
(`Sources/APIServer/Configuration/`). `configure(_:)` loads the entire tree
once via `AppConfig.fromEnvironment(workDir:)`, stashes it on
`Application.appConfig`, and logs a redacted summary. Subsystems read typed
substructs (`auth`, `security`, `workers`, `oidc`, `database`, `lockout`,
`diagnostics`, `alerts`, `brightspace`, `scanMode`) — never `Environment.get`
directly. Tests preload an `AppConfig` via `Application.preloadedAppConfig`
(checked first by `configure(_:)`) or pass one to `makeTestApp(appConfig:)`.

A grep guardrail (`grep -rn "Environment.get" Sources/APIServer/`) must only
return hits under `Sources/APIServer/Configuration/`.

## Key Design Constraints

These are the load-bearing decisions that future work should respect:

- **No Vapor in `Core/`.** All `Core` types must be `Codable`, `Sendable`, and
  framework-free so the runner can import them without pulling in Vapor.

- **No `CouldNotRun` test status.** Build failures are recorded at the
  collection level (`buildStatus: .failed`, `outcomes: []`), not as individual
  test outcomes.

- **No runner JSON protocol.** The runner maps exit codes to
  `TestStatus` directly. Scripts communicate results via exit code + optional
  last-line JSON on stdout.

- **No per-language build strategies in Swift.** New languages require new
  shell scripts by the instructor, not Swift changes. The Python normalization
  layer in `SubmissionNormalizer` is a submission-format concern — the grading
  scripts remain language-agnostic.

- **Swift 6 strict concurrency.** All shared mutable state goes through actors.
  `@unchecked Sendable` must include a comment explaining why it is safe.

- **No force unwraps outside tests.** Use `guard`/`if let` or throw explicit
  errors.
