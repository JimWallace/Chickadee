# Chickadee — Architecture

Status: current as of the 0.5.0 cleanup pass (2026-07).

## Overview

Chickadee is a student code submission and autograding system written in Swift
using the Vapor framework. It replaces Marmoset (University of Maryland, Java)
with a clean-break rewrite targeting macOS and Linux.

The system has three responsibilities:

1. **Accept** student submissions (files or notebooks) via a web UI or API.
2. **Grade** them by running instructor-authored test scripts — either in an
   isolated subprocess on a worker, or in the browser via the same grading
   core compiled to WebAssembly.
3. **Return** structured results to the student and instructor.

---

## Targets & Packages

```
                ┌──────────────────────────────────────────────┐
                │                  RunnerCore                  │
                │  Vapor-free, Embedded-Swift-compatible       │
                │  grading core (Swift stdlib only)            │
                │  executeSuites · interpretScriptOutput ·     │
                │  script classification · notebook extraction │
                │  TestOutcome · TestTier · TestStatus         │
                └─────────┬──────────────────────┬─────────────┘
       @_exported through │                      │ compiled to wasm32 by
                     Core │                      │ the wasm/ sub-package
                          ▼                      ▼
                ┌──────────────────┐   ┌──────────────────────────┐
                │       Core       │   │  Public/runner-wasm/     │
                │  shared models   │   │  RunnerWasm.<hash>.wasm  │
                │  (no Vapor)      │   │  + runner-core.js bridge │
                └────┬────────┬────┘   │  (in-browser grader)     │
                     │        │        └──────────────────────────┘
          ┌──────────┘        └──────────┐
          ▼                              ▼
┌────────────────────┐        ┌─────────────────────┐
│ APIServer library  │        │  chickadee-runner   │
│ + chickadee-server │        │  (Sources/Worker)   │
│   executable       │        │  daemon process     │
│                    │        │                     │
│ REST API           │◄───────┤ polls /worker/      │
│ Leaf web UI        │        │ request             │
│ Auth / sessions    │───────►│ receives Job        │
│ DB (Fluent)        │        │ runs test scripts   │
│ File storage       │◄───────┤ POST /worker/       │
│ Observability      │        │ results             │
└────────────────────┘        └─────────────────────┘
```

Targets, as declared in `Package.swift`:

- **`RunnerCore`** — the shared grading core. Dependency-free (Swift stdlib
  only) so it compiles both natively and to wasm32 under Embedded Swift. It
  owns suite execution (`executeSuites`), output interpretation
  (`interpretScriptOutput`), script classification (extension → shebang →
  content), notebook extraction (`extractPython` / `extractR`), the
  `TestOutcome` / `TestTier` / `TestStatus` types, and an embedded-safe JSON
  layer (`JSONLite`). Because the native worker and the browser runner drive
  the same loop, the two graders cannot drift; parity is pinned by
  `Tests/Fixtures/output-contract.json`, asserted in CI against both the
  native build and the real vendored wasm.
- **`Core`** — shared `Codable`/`Sendable` models (Job, TestProperties,
  PatternFamily, Achievement, CourseBundleManifest, …). No Vapor dependency.
  Depends on `RunnerCore` and re-exports it (`@_exported import RunnerCore`
  in `RunnerCoreExports.swift`), so grading types are visible everywhere
  `Core` is.
- **`APIServer`** — the bulk of the server as a library, so tests link the
  library instead of relinking an executable.
- **`chickadee-server`** — thin executable wrapper that calls
  `runAPIServer()`; the binary name deploy scripts expect.
- **`chickadee-runner`** — the worker executable (source directory
  `Sources/Worker/`).
- **`wasm/`** — a separate SwiftPM package that compiles `RunnerCore` to
  WebAssembly through a JS bridge. The artifact is vendored and checked in at
  `Public/runner-wasm/` (`RunnerWasm.<contenthash>.wasm` + `runner-core.js`),
  immutably cached (`RunnerWasmCacheMiddleware`), and size-guarded in CI. See
  [`runner-wasm-migration.md`](runner-wasm-migration.md) and
  [`runner-wasm-serving.md`](runner-wasm-serving.md).

`chickadee-server` and `chickadee-runner` communicate over HTTP. The runner
never calls any Swift API from the server — the boundary is the wire protocol.
This means the runner can be deployed on a completely different host or inside
a Docker container with no shared filesystem.

### Source layout

```
Sources/
  RunnerCore/               Shared grading core (stdlib only; native + wasm)
    SuiteExecution.swift    executeSuites — the one suite-execution loop
    OutputInterpretation.swift  exit code + last-line JSON → status/score
    ScriptClassification.swift  extension → shebang → content dispatch
    ScriptExecutor.swift    substrate protocol (native and browser executors)
    NotebookExtraction.swift    extractPython / extractR
    TestOutcome.swift · TestStatus.swift · TestTier.swift · JSONLite.swift
  Core/                     Shared models (no Vapor; re-exports RunnerCore)
    Models/ + top-level     Job, TestProperties, PatternFamily, Achievement,
                            AssignmentLanguage, SlipDayPolicy, …
  APIServer/                Server library (tests link this, not the executable)
    Routes/                 REST + web route handlers
      Web/                  Leaf-rendered instructor/admin/student pages
    Middleware/             Auth, CSRF, HTTPS redirect, security headers, …
    Models/                 Fluent model classes (DB-mapped)
    Migrations/             Ordered migration chain
    Auth/                   OIDC/SSO configuration and claims
    MCP/                    Content-authoring MCP + OAuth 2.1 AS
      Admin/                Read-only admin diagnostics MCP surface
    Configuration/          AppConfig — every env var read
    Bootstrap/ Services/ Diagnostics/ Helpers/ Utilities/ …
  chickadee-server/         Thin executable wrapper (calls runAPIServer())
  Worker/                   chickadee-runner executable
    RunnerDaemon.swift      WorkerDaemon actor + poll/execute slots
    NativeScriptExecutor.swift  RunnerCore ScriptExecutor over Process
    ScriptRunner.swift      ScriptRunner protocol + UnsandboxedScriptRunner
    SandboxedScriptRunner.swift
    SubmissionNormalizer.swift · NotebookExtractor.swift · MimeTypeDetector.swift
    TestRuntimeSources.swift    Embedded Python + R runtime sources
    TestSetupCache.swift    LRU cache of prepared test setup directories
wasm/                       SwiftPM sub-package: RunnerCore → wasm32 bridge
Public/runner-wasm/         Vendored wasm artifact + JS bridge (checked in)
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
                                                          (TestSetupCache reuses prepared setups)
                                                        • SubmissionNormalizer (Python jobs)
                                                        • extractNotebooksToCode (ipynb → .py/.R)
                                                        • Write test_runtime.py / test_runtime.R
                                                        • Write _ck_inputs.py / _ck_inputs.R
                                                          (per-student personalized values)
                                                        • Optional: run make
                                                        • executeSuites (RunnerCore) via
                                                          NativeScriptExecutor + ScriptRunner
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

Browser-graded assignments run the *same* `executeSuites` loop, compiled to
wasm, against a Pyodide substrate (`Public/browser-runner.js` /
`grading-worker.js`, seeded through `BrowserRunnerRoutes`), and post their
results to the server. A worker backstop regrades browser-mode submissions
that never complete in the browser, using native `python3` with matching
semantics.

---

## Python / Notebook Submission Normalization

Before the test scripts run, the runner preprocesses Python submissions
through a normalization pipeline:

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

`extractNotebooksToCode` (in `Sources/Worker/NotebookExtractor.swift`,
delegating the cell extraction to RunnerCore) handles the instructor side: it
converts `.ipynb` files in the test setup directory to `.py` or `.R` before
the test scripts run. This is separate from student submission normalization
and runs for all jobs, not just Python ones.

The shell scripts themselves remain language-agnostic. Normalization is a
submission-format concern, not a grading concern.

---

## Authentication & Roles

### Roles

Roles are two-level (#417): a deployment role plus a per-course role.

- **Deployment role** (`UserRole` on `APIUser`): `user` < `admin`, plus the
  non-login `mcp` service-account role. There is no deployment-global
  student or instructor role — the legacy global roles were retired by the
  #417 multi-course-roles series (`CollapseUserRoles` migration).
- **Course role** (`CourseRole` on the enrollment row): `student` < `ta` <
  `instructor`. One account can be an instructor in one course and a student
  in another. TAs author content and grade but cannot manage enrollment,
  deadlines, archival, or staff.

Enforcement chokepoints: `requireCourseRole(atLeast:)` / `evaluateCourseWrite`
in `Sources/APIServer/Helpers/CourseAccessHelpers.swift` (the web UI and the
MCP tools share this policy); the `/instructor` area gate is
`ActiveCourseStaffMiddleware` (staff in the *active* course), with
per-resource gates on every parameterized route. `RoleMiddleware` survives
but knows only `.authenticated` and `.admin`. Admins bypass per-course role
checks; MCP agents acting on an admin's behalf stay enrollment-scoped. See
[`multi-course-roles.md`](multi-course-roles.md).

### Auth modes

`AUTH_MODE` env var selects the active mode:

| Mode | Behaviour |
|------|-----------|
| `.local` | Username + bcrypt password stored in `users` table |
| `.sso` | OIDC Authorization Code + PKCE against an external IdP |
| `.dual` | Both active simultaneously; SSO is the primary path |

SSO implementation lives in `SSOAuthRoutes.swift` and `OIDCConfiguration.swift`.
The discovery document and JWKS are fetched from `OIDC_AUTH_SERVER` at startup.
Admin assignment uses the `SSO_ADMIN_USERS` allowlist (comma-separated, checked
against JWT claims on every login); instructor authority is per-course
(assigned from the course roster), so there is no SSO instructor allowlist.

`ENABLE_NON_SSO_AUTH_MODES` controls whether `.local` and `.dual` are available
(useful when the deployment policy mandates SSO-only).

### Session management

Vapor's `SessionAuthenticator` with the Fluent session driver (v0.4.46+):
sessions are persisted in the database, so they survive restarts and work
across multi-process deployments. Session cookie is `HttpOnly; SameSite=Lax`.
The `Secure` flag is set automatically when `PUBLIC_BASE_URL` is `https://`
or auth mode is non-local.

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
`WorkerClaimQueue` — a Swift actor (in `WorkerJobRoutes.swift`) eagerly
initialised at server startup. The actor executes claim transactions one at a
time; each transaction atomically finds a pending job and marks it assigned.

### WorkerDaemon concurrency

The runner side uses structured concurrency: `WorkerDaemon` spawns one `Task`
per slot (up to `--max-jobs`). Each slot runs its own poll/execute loop
independently. `activeJobs` is a mutable `Int` on the actor, incremented at
job start and decremented when the job ends.

### Timeout handling

Script timeouts use a structured child `Task` that sleeps for
`timeLimitSeconds` and then sends `SIGKILL` to the process group. This keeps
timeout logic within Swift's cooperative concurrency model rather than using
`DispatchQueue`.

### Sweeps and reapers

Server-side periodic monitors handle stuck state: a stuck-submission reaper
reclaims `assigned` submissions whose runner disappeared, a deadline sweep
auto-closes assignments past their due date, a session reaper drops expired
sessions, and an hourly OAuth reaper deletes dead MCP grant rows.

---

## Test Script Contract

Each test suite is a script at the root of the instructor's test setup zip.
Dispatch is by classification (RunnerCore `ScriptClassification.swift`): a
recognised extension wins, else the `#!` shebang, else content sniffing — so
`.sh` scripts run with `/bin/sh` and Python test files (including
extensionless ones with a shebang) run with the Python interpreter.

| Exit code | Meaning |
|-----------|---------|
| 0 | pass |
| 1 | fail |
| 2 | error |
| killed after timeout | timeout |

**stdout:** Everything is ignored except the last non-empty line, which is
parsed as optional JSON `{ "score": 0.75, "shortResult": "3/4 passed" }`.
If not valid JSON, the line is used as plain-text `shortResult`. If stdout is
empty, `shortResult` is synthesized from the exit code. `score` (clamped to
`0...1`) carries partial credit — the test contributes `points × score` — and
is orthogonal to the exit code; a script that emits no `score` grades full
credit on a pass and none otherwise.

**stderr:** Captured verbatim as `longResult` (nil if empty).

Test dependencies can be declared in `TestProperties.testSuites[].dependsOn`.
If a prerequisite did not pass, dependents are automatically recorded as
`fail` with the exact message produced by
`skippedPrerequisiteMessage(prerequisite:)` in RunnerCore
(`Skipped: prerequisite '…' did not pass`) — both the native and browser
graders share that code path, and a skipped test scores 0.

Instructors are not limited to hand-written scripts: pattern families and
notebook checks (see [Authoring subsystems](#authoring--personalization-subsystems))
are expanded into ordinary generated test scripts at save time, so the runner
only ever sees scripts.

---

## Runner Sandboxing

`ScriptRunner` is a protocol with two implementations:

```swift
protocol ScriptRunner: Sendable {
    func run(script: URL, workDir: URL, timeLimitSeconds: Int, env: [String: String]) async -> ScriptOutput
}

struct UnsandboxedScriptRunner: ScriptRunner { … }   // default in development
struct SandboxedScriptRunner: ScriptRunner { … }     // --sandbox flag
```

`SandboxedScriptRunner` uses platform-specific primitives:
- **macOS:** `sandbox-exec` with a generated profile
- **Linux:** `unshare --user --net --map-root-user` to drop privileges and
  isolate the network namespace

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

`WorkerHMACAuthMiddleware` validates each request (the signing code is shared
via `Core/WorkerHMACSigning.swift`). The shared secret is auto-generated from
a three-word EFF diceware passphrase on first startup and persisted to
`.worker-secret`. The runner reads it from `RUNNER_SHARED_SECRET` (env var or
`.worker-secret` file). The admin dashboard can rotate the secret at runtime.

---

## Database & Migrations

`DatabaseConfiguration` (`Sources/APIServer/Utilities/DatabaseConfiguration.swift`)
selects the backend from `DATABASE_URL`:
- `postgres://…` → Fluent PostgreSQL driver
- absent / `sqlite://…` → Fluent SQLite driver (default for development)

SQLite deployments enable WAL journaling and foreign key enforcement at startup.

Migrations are registered in order by `registerMigrations(on:)` in the same
file. The steady-state convention:

- **Canonical `Create<Model>` files** own each table's full current shape.
  Incremental `Add<Feature>` / `Change<Feature>` migrations carry deployed
  databases forward between consolidation boundaries.
- **Consolidation boundaries fold incrementals into their `Create*` files
  and delete them outright.** Fluent ignores `_fluent_migrations` history
  rows whose struct names are no longer registered, so production databases
  that already ran a deleted migration are unaffected, and fresh deploys
  build the same final schema from the `Create*` files alone. The first
  round (#502/#505) shipped before this pass; a second round lands with the
  0.5.0 cleanup, folding the post-#502 incrementals. A handful are
  deliberately kept as standalone migrations: `AddUserFKConstraints`, the
  two slip-day migrations (`AddCourseSlipDaySettings`,
  `AddEnrollmentSlipDaysAdjustment`), `AddSessionsCreatedAt` (it targets
  Vapor's own sessions table, which no `Create*` file owns), and
  `CollapseUserRoles` (a pure data rewrite with no schema home).
- **Not every migration is additive.** `ChangeAssignmentIsOpenToVisibility`
  converted the boolean `is_open` into the three-state `visibility` column
  and dropped `is_open`; `CreateResultCollections` moved
  `results.collection_json` into a side table and dropped the original
  column. Treat column existence as migration-order-dependent.
- **`MigrationNamespaceReconciler`** runs after registration and before
  `autoMigrate`: it rewrites `_fluent_migrations` rows recorded under legacy
  module-derived name prefixes (`chickadee_server.`, `APIServer.`) to the
  canonical `chickadee.*` namespace pinned by `ChickadeeMigration`, so a
  database restored from a pre-rename build migrates cleanly instead of
  re-running already-applied migrations.

For the current set, see `Sources/APIServer/Migrations/`.

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
runner load, rolling averages, and compatibility counters. The same telemetry
— plus deploy status, health alerts, browser diagnostics, and log queries —
is exposed read-only to agents through the admin diagnostics MCP surface
(see [MCP surfaces](#mcp-surfaces)).

See [`operational-diagnostics.md`](operational-diagnostics.md) for the full
field reference, structured log event catalogue, and ops runbook.

---

## JupyterLite & Vendored Browser Libraries

A full JupyterLite instance lives at `Public/jupyterlite/`. It powers two
workflows:

1. **Student submission:** students edit their notebook in-browser and submit
   without leaving the page.
2. **Instructor authoring:** instructors create and validate assignments
   in-browser (edit/save/validate cycle).

The embedded content is generated output checked into the repo. Rebuild only
when updating kernel versions:

```bash
scripts/setup-jupyterlite.sh
scripts/build-jupyterlite.sh
scripts/setup-vendor.sh
```

`JupyterLiteContentsRoutes` serves the JupyterLite contents API. It maps
JupyterLite file paths to the server's test setup storage so the notebook
editor reads and writes the canonical `.ipynb` files directly.

Pyodide, jszip, and CodeMirror are vendored under `Public/` rather than
loaded from third-party CDNs, so student and instructor IPs are not leaked on
every page load (FIPPA/PIPEDA). There is exactly **one canonical Pyodide**
(`Public/pyodide/`, served at `/pyodide`) and both consumers load it: the
JupyterLite editor kernel and Chickadee's own browser grading paths. Its
version is not hardcoded — `scripts/setup-vendor.sh` derives it from the
pinned `jupyterlite-pyodide-kernel` wheel, and
`scripts/check-pyodide-parity.sh` fails CI if the vended copy ever drifts
from the kernel's pin.

---

## BrightSpace grade sync

Chickadee can push grades to D2L BrightSpace. It is off unless the server has
BrightSpace credentials configured (`AppConfig.brightspace`, set from
`BRIGHTSPACE_*` env vars); when present, `app.brightSpaceClient` is non-nil.

**Auth model.** D2L Valence "App + User" key signing — one registered app +
one D2L service account. Every push runs *as that one account* with its
permissions; there is no per-instructor D2L identity. Credentials live only in
env (ops-managed) and are never shown in the UI. `BrightSpaceAPIClient` signs
each request URL per call (HMAC-SHA256) — no token endpoint.

**Where grades land** is decided entirely by two IDs, not the credentials:

- **Org unit ID** (`courses.brightspace_org_unit_id`) — the D2L course. Because
  the service account can usually write to many courses, this binding is an
  **admin-only** action on the course page, and it is **verified on save**: the
  server looks the ID up via `getOrgUnit` and caches the D2L name
  (`brightspace_org_unit_name`) so the admin can confirm they pointed at the
  right course. Instructors are then locked to their bound course.
- **Grade object ID** (`assignments.brightspace_grade_object_id`) — the grade
  item (column). Instructors map these on the BrightSpace tab, picking from a
  dropdown sourced from `listGradeObjects` (free-text fallback).

**Student identity.** A Chickadee user is matched to a LEARN account against the
course **classlist**, by `username` (the WatIAM id, primary) then `student_id`
(the D2L `OrgDefinedId`, fallback — incl. the legacy `lookupUserID`
`users/?orgDefinedId=` call). The resolved internal D2L user id caches on
`users.brightspace_user_id` on first sync and is reused thereafter. Students
with no resolvable account surface in the BrightSpace tab's "unmapped students"
list.

**Sync engine.** On a worker result save, `ResultRoutes` flags the `APIResult`
row pending. `BrightSpaceGradeSyncMonitor` sweeps every 60 s and pushes the
**best (max) points** per (student, assignment) past a debounce window
(`BRIGHTSPACE_SYNC_DEBOUNCE_SECS`, default 90 s). Each meaningful event
(success, push failure, or skipped-no-account) appends a row to
`brightspace_sync_log` — an append-only audit trail snapshotting identity
fields so it survives course/assignment/user deletes. The BrightSpace tab
renders this log plus summary counts, and offers manual **Sync now**, **Retry
failed**, and per-assignment **Push all** (backfill) actions that re-flag rows
and run an immediate (debounce-bypassing) sweep.

Operator runbook: [`brightspace-setup.md`](brightspace-setup.md).

---

## MCP surfaces

Chickadee exposes two Model Context Protocol servers, both implemented under
`Sources/APIServer/MCP/`. Chickadee is its own OAuth 2.1 **authorization
server** for both: Authorization Code + PKCE (S256) in the browser, dynamic
client registration, rotating refresh tokens with prior-hash theft detection,
short-lived ES256 access JWTs (`MCPTokenAuthority`), and strictly single-use
codes/consent tokens consumed via an atomic conditional
`UPDATE … WHERE consumed = false RETURNING`, so concurrent exchanges cannot
replay a code. The human's role is re-checked at consent and on every
refresh; an hourly reaper drops dead OAuth rows.

### Content authoring (`POST /mcp`)

Lets an agent author course content on an instructor's behalf. Gated by
`MCP_MODE` (`off` / `read_only` / `read_write`); scopes are clamped to the
mode ceiling. The catalog holds **52 tools** — `MCPToolCatalog.live` in
`Sources/APIServer/MCP/Transport/MCPServerRegistration.swift` is the source
of truth — covering course/assignment/suite/notebook/solution reads, suite +
pattern-family + notebook-check + script authoring, course sections and
content items, personalization inputs, achievements, validation, and
assignment version history/restore. The surface deliberately exposes **no
student data, grades, enrollment, or submissions**, and agents are
enrollment-scoped even when the authorizing human is an admin. Content edits
close a currently-open assignment for re-validation and auto-regrade existing
submissions when the graded suite actually changed.

The transport is **dual-era**, resolved per request: a body whose `_meta`
carries `io.modelcontextprotocol/protocolVersion` gets the 2026-07-28
revision's semantics (mandatory `server/discover`, `resultType` + server
`_meta`, mirrored protocol headers); anything else keeps the legacy
`initialize` handshake behaviour. See
[`mcp-2026-07-28-revision.md`](mcp-2026-07-28-revision.md) and the tool index
in [`mcp-authoring-roadmap.md`](mcp-authoring-roadmap.md).

### Admin diagnostics (`POST /admin-mcp`)

A separate, **read-only** surface for operational diagnosis: **19 tools** in
`AdminMCPToolCatalog` (`Sources/APIServer/MCP/Admin/`) — deployment/version
info, deploy status and history, queue state, runner listing and detail,
metrics snapshots and timeseries, storage usage, health alerts, browser
diagnostics, connected agents, BrightSpace sync status, and log/audit-log
queries. It mounts whenever the content surface does (any non-off
`MCP_MODE`), stays read-only regardless of mode, requires the admin role plus
the `diagnostics:read` scope, and never exposes student data. Design record:
[`admin-mcp.md`](admin-mcp.md).

---

## Authoring & Personalization Subsystems

Orientation only — each pointer doc carries the full design.

**Per-student personalization.** Each (student, assignment) pair gets a
deterministic seed. Instructors declare Global Inputs and section variables —
literal values or per-student `=` expressions — referenced as `{{name}}` in
notebooks and `$name` in pattern-family cells. Expressions are evaluated
**server-side** by `PersonalizationEvaluator`, which spawns `python3` or
`Rscript` per the assignment language, so expression source and the reference
solution never reach the runner; only resolved values are delivered to
grading as a `_ck_inputs.py` / `_ck_inputs.R` preamble (worker job payload or
browser seed endpoint). See [`inputs.md`](inputs.md),
[`personalization-phase1.md`](personalization-phase1.md),
[`personalization-pattern-families.md`](personalization-pattern-families.md),
and [`personalization-eval-runtime.md`](personalization-eval-runtime.md).

**Pattern families and notebook checks.** A `PatternFamily` (Core) is one
function, shared defaults, and a table of cases; `applyPatternFamilies`
expands each enabled case into an ordinary generated test script at save time
(deterministic filenames, a `spec_hash` header, and a `generatedBy` marker so
the raw-script edit endpoints refuse to mutate them). Eight kinds ship, from
`boundaryEquality` to `unorderedEquality`. Notebook checks (ten
`NotebookCheckKind`s, e.g. `variableExists`, `astStructure`) render the same
way. The grading path never knows: workers and the browser runner only see
scripts.

**First-class R.** `AssignmentLanguage` (`.python | .r`, Core) is resolved
from the manifest, and every language-specific path dispatches through it —
literal rendering, the per-student inputs file, the expression driver, and
the pattern-family / notebook-check renderers. `astStructure` remains the one
Python-only check kind. See [`r-support.md`](r-support.md).

**Assignment versioning.** Every persisted change to an assignment's content
records an immutable snapshot (`AssignmentVersionCaptureMiddleware`);
course staff can list, read, and restore versions (currently over MCP). See
[`assignment-versioning.md`](assignment-versioning.md).

**Slip days.** A per-course budget of student-managed deadline extensions,
spent self-serve with no staff involvement (`SlipDayPolicy` in Core). See
[`slip-days.md`](slip-days.md).

**Achievements.** Per-assignment achievements — collaborative class goals and
individual badges such as First-Try Perfect — are declared as data
(`Achievement` in Core) and evaluated server-side from submission results
(class-goal progress via the periodic `AchievementEvaluationService` sweep);
editable in the assignment editor and over MCP. Plan of record:
[`achievements-unification.md`](achievements-unification.md).

**Per-student datasets.** A `DatasetSpec` marks a bundled support file as
per-student; the server materializes a deterministic per-seed slice delivered
under the same filename to grading and the editor. See
[`datasets.md`](datasets.md).

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

### Production CI/CD (blue-green)

Production is full CI/CD with zero-downtime deploys: a green merge to `main`
auto-releases (version computed, changelog fragments folded, tag pushed) and
publishes an image; a host-side daemon, `chickadee-deployer`
(`deploy/chickadee-deployer.sh`), polls GitHub Releases and blue-green-deploys
each release via `scripts/bluegreen-deploy.sh` — the new "color" container
boots beside the live one, is health-gated, the nginx upstream flips with no
dropped requests, and the old color drains and stays for instant rollback.
Non-major bumps deploy unattended; major bumps hold for human approval. Each
deploy snapshots first and auto-rolls-back if the new version degrades after
cutover. The admin-MCP deploy tools are strictly read-only; deploy control is
host-side by design. See [`zero-downtime-deploy.md`](zero-downtime-deploy.md).

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
`diagnostics`, `alerts`, `brightspace`, `mcp`, `scanMode`) — never
`Environment.get` directly. Tests preload an `AppConfig` via
`Application.preloadedAppConfig` (checked first by `configure(_:)`) or pass
one to `makeTestApp(appConfig:)`.

A grep guardrail (`grep -rn "Environment.get" Sources/APIServer/`) must only
return hits under `Sources/APIServer/Configuration/`.

## Key Design Constraints

These are the load-bearing decisions that future work should respect:

- **No Vapor in `Core/`, nothing but the stdlib in `RunnerCore/`.** `Core`
  types must be `Codable`, `Sendable`, and framework-free so the runner can
  import them without pulling in Vapor. `RunnerCore` goes further — Swift
  stdlib only — because it must compile under Embedded Swift to wasm32.

- **One grading implementation.** Grading-semantics changes land in
  `RunnerCore` and must keep `Tests/Fixtures/output-contract.json` green for
  both the native build and the vendored wasm; never fork behaviour between
  the worker and the browser runner.

- **No `CouldNotRun` test status.** Build failures are recorded at the
  collection level (`buildStatus: .failed`, `outcomes: []`), not as individual
  test outcomes.

- **No runner JSON protocol.** The runner maps exit codes to
  `TestStatus` directly. Scripts communicate results via exit code + optional
  last-line JSON on stdout.

- **No per-language build strategies in Swift.** New languages require new
  test scripts by the instructor, not Swift changes. The Python normalization
  layer in `SubmissionNormalizer` is a submission-format concern — the grading
  scripts remain language-agnostic.

- **Swift 6 strict concurrency.** All shared mutable state goes through actors.
  `@unchecked Sendable` must include a comment explaining why it is safe.

- **No force unwraps outside tests.** Use `guard`/`if let` or throw explicit
  errors.
