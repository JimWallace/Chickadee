# Chickadee — Architecture

Status: current as of the 0.5.0 cleanup pass (2026-07). The browser grading
and vendored-library sections were corrected in 2026-10, after Pyodide was
removed (v0.5.19).

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
    BrightSpace/ GitHub/ LTI/   One directory per LMS or forge integration
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

Inside `APIServer/`, `Services/`, `Helpers/` and `Utilities/` sit below
`Routes/`: a route calls down into them, and they never call up into a route.
The feature directories that hold only services, `BrightSpace/` and `GitHub/`,
are shared code too. `scripts/check-layering.sh` enforces it in `format-lint`.
It fails when a file under any of those five directories names a function or
type declared only under `Routes/`. `LTI/` is not scanned, because it holds its
own routes. The uses that predate the rule are listed in
`scripts/layering-baseline.txt`, and that list can only shrink (#1726).

Each of those directories has one job, so a file goes where its imports say:

- `Utilities/` holds pure code: no request and no database.
  `scripts/check-utilities-imports.sh` fails when a file there imports Vapor or
  a database module (#1730). The authoring validators throw
  `AuthoringValidationError`, so no file there imports Vapor (#1929).
- `Helpers/` holds code that works with a `Request` or a database driver type.
  The same script fails when a file there imports none of Vapor, Fluent and
  Leaf and names no model, because such a file is pure (#2144).
- `Services/` holds code over models, a database and the application.
- `Bootstrap/` holds app setup: the database configuration and the migration
  registry, the session driver, and the migration-namespace reconciler.

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
wasm, against a xeus kernel substrate: `RoutingExecutor` in
`Public/grading-executors.js` sends each script to the vendored kernel for its
language (xeus-python, xeus-r, xeus-lua or xeus-octave) through that
language's `*-grading-worker.js`, seeded through `BrowserRunnerRoutes`, and the
page posts the results to the server. A worker backstop regrades browser-mode
submissions that never complete in the browser, on the native worker.

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
- **Linux:** `unshare --user --net --mount --map-root-user` to drop
  privileges, isolate the network namespace, and give the script a private
  mount namespace in which the work root is covered by an empty tmpfs and
  only the job's own directories are bound back (#2061)

The sandbox boundary is at the subprocess level. Swift never imports a JVM,
Python interpreter, or any language runtime — all language execution goes
through `swift-subprocess` (`runBounded`).

### What in-process grading does not protect

Most generated tests load the submission into the test's own process. Python
imports it as a module. R and Octave evaluate its source. Lua loads it into an
environment table, and Racket requires it as a module. C++ compiles it into
the test binary, and Java compiles it into the test program. So the submission
and the test are one process. (A `programIO` test in C++ or Java is the
exception. It runs the submission as a separate process; see
[program-io.md](program-io.md).)

This lets the submission read the values of the test that runs it. The
expected value is one of these values. Each runtime gives a way to read them:

- Python: `inspect.stack()` returns the call stack, and the test's frames
  are on it.
- R: `sys.frames()` returns the call stack, and the test's frames are on it.
- Lua: `debug.getlocal` reads the locals of the test chunk. A Lua audit in
  2026-08 used this to print `expected_output`, and the test passed.

The submission can also read the files in its working directory. On the
native worker, this directory is the test setup directory. It holds every
script in the suite, of every tier. It also holds the grader-only files and
the per-student inputs file. Neither sandbox prevents a read.

A submission can send what it reads to the student. For example, a generated
test puts the text of an exception from the submission into its failure
message. On a public test, the student sees that text at the `full` and
`actualOnly` levels of [failure detail](failure-detail.md).

The boundary is the process, not the stack frame. That boundary still gives
these protections:

- **The server.** Student code runs on a runner, never in the server process.
  A script gets an allowlisted environment, so it does not inherit the
  runner's shared secret (`Sources/Worker/ScriptRunner.swift`). The runner
  also marks itself non-dumpable at start, so a script cannot read the
  secret from the runner's own `/proc` entries.
- **The host, with `--sandbox`.** The script cannot reach the network. On
  Linux it has no real privileges. On macOS it can write only in its working
  directory. Without `--sandbox`, the script runs as the runner's user, with
  network access. The manifest's `make` step runs in the same sandbox as the
  scripts (#2250); until then it ran outside it, even with `--sandbox`. When
  the manifest has a make step, a submission cannot supply `Makefile`,
  `makefile` or `GNUmakefile` (`protectedWorkspaceFilenames`), because the
  submission is merged before `make` runs and GNU make reads `GNUmakefile`
  first.
- **Other jobs on the same runner, with `--sandbox`.** Every job on a runner
  runs as the same user, and every job directory is a child of one work root.
  So while two jobs run at the same time (`--max-jobs` above 1), a script
  could read the other job's workspace, which holds another student's
  submission. The sandbox hides it (#2061): on Linux the script runs in a
  private mount namespace in which the work root is covered by an empty
  tmpfs, and only the script's working directory and the directories its
  environment names (`CHICKADEE_OPPONENT_DIR`) are bound back. On macOS the
  profile denies the work root and allows the same directories. Nothing is
  configured: the work root is the parent of the working directory, because
  the runner creates both. Without `--sandbox`, the workspaces are shared. A
  class-activity match job stages a classmate's submission as the opponent,
  by design (see [class-activities.md](class-activities.md)).
- **The job's other test scripts, with `--sandbox`.** While one suite script
  runs, the job's other suite scripts read as empty on Linux (each is covered
  with `/dev/null` in the script's mount namespace) and are denied on macOS. A
  public test's submission can then no longer read the release and secret test
  scripts beside it. Its own script, the support files (grader-only ones
  included, because tests use them) and the per-student inputs stay readable
  (`NativeScriptExecutor.scriptsHidden`; [grading-integrity.md](grading-integrity.md),
  phase 2).
- **The processes of other jobs on the same runner, with `--sandbox` on
  Linux.** Every job runs as the same user, so one job could once fork until
  the container's `pids_limit` was used up, and the jobs beside it could then
  not start a process. Each script now starts under its own `RLIMIT_NPROC`
  (`--job-process-limit`, default 128; #2224). The kernel counts it per user
  namespace (Linux 5.14 and later), and each script has its own, so it counts
  only that script's processes and threads. A JVM needs about 20 on four
  CPUs, more on a larger host. Two conditions apply, and the runner warns at
  startup when either fails: the runner must not run as root, because the
  kernel does not apply the limit then; and the container's `pids_limit` must
  hold every job at its limit (`--max-jobs` x limit + 64,
  `JobProcessBudget`).
- **The disk of other jobs on the same runner, with `--sandbox` on Linux.**
  Every job directory lives on one mount that the jobs on a runner share, so
  one script that wrote without bound in its working directory once filled it
  for every job. Now an overlay covers the working directory: the script reads
  the job's files through it, and what it writes goes to a private tmpfs of
  `--job-disk-limit` megabytes (default 256; #2251), which is discarded when
  the script ends. A full space fails only that script. No test reads a file
  an earlier test wrote, and the runner reads only a script's output, so
  nothing depends on the writes; a Java test recompiles rather than reuse an
  earlier test's classes. The make step keeps its writes, because the tests
  use what it builds. An opponent directory is read-only. The overlay needs
  Linux 5.11 or later, and the startup probe includes it. Memory is still
  shared by the jobs on a runner (#2252); the private tmpfs counts against it.

This is a property of the design, not a defect. Treat each value in a test,
and each file in its test setup, as visible to a determined student. To hide
an expected value, a test must keep it out of the submission's process and
out of the files that the submission can read. That is a design change. It
adds a process start to each test, in each language.

Browser grading has a wider limit. The student's browser receives the whole
test setup, less the grader-only files. So a student can open every test in
their own browser, without a submission (see
[failure-detail.md](failure-detail.md) and [datasets.md](datasets.md)).

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
`.worker-secret` file). The admin dashboard neither shows nor changes it.

---

## Database & Migrations

`DatabaseConfiguration` (`Sources/APIServer/Bootstrap/DatabaseConfiguration.swift`)
selects the backend from `DATABASE_BACKEND` (`DatabaseSettings.fromEnvironment`):
- `postgres` → Fluent PostgreSQL driver, connected from `DATABASE_HOST`,
  `DATABASE_NAME`, `DATABASE_USER`, `DATABASE_PASSWORD` and `DATABASE_PORT`
- absent / `sqlite` → Fluent SQLite driver (default for development), at
  `SQLITE_PATH` or the default file under the working directory

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
  0.5.0 cleanup, folding the post-#502 incrementals. A third round (#1252)
  folded the two slip-day migrations. A fourth round (#1806) folded 15
  column and index migrations, from the avatar columns to the per-term
  course-code index. A handful are deliberately kept as
  standalone migrations: `AddUserFKConstraints`, `AddSessionsCreatedAt` (it targets
  Vapor's own sessions table, which no `Create*` file owns),
  `CollapseUserRoles` (a pure data rewrite with no schema home), and
  `AddLTIGradeSyncFailureReasonColumn` (it backfills existing rows).
- **Not every migration is additive.** `CreateResultCollections` moved
  `results.collection_json` into a side table and dropped the original
  column, and the assignment table's boolean `is_open` became the three-state
  `visibility` column in a migration since folded into `CreateAssignments`.
  Treat column existence as migration-order-dependent.
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

jszip and CodeMirror are vendored under `Public/vendor/`, and the editor
kernels under `Public/jupyterlite/xeus/`, rather than loaded from third-party
CDNs, so student and instructor IPs are not leaked on every page load
(FIPPA/PIPEDA). Each kernel is built from its own emscripten-forge environment
(`Tools/jupyterlite/environment-*.yml`), and the same vendored kernels serve
both the JupyterLite editor and browser grading. `scripts/check-xeus-vendored.sh`
guards the vendored bytes, and `scripts/check-env-vendored-sync.sh` fails a PR
whose environment files have drifted from them.

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
replay a code. Codes, consent tokens and refresh tokens are stored only as
SHA-256 hashes. The human's role is re-checked at consent and on every
refresh; an hourly reaper drops dead OAuth rows. Scopes are clamped to the
mode ceiling, and `MCPMode.advertisedScopes` is the single source for both
discovery and dynamic client registration. `MCPBearerAuthMiddleware` does the
bearer authentication and clamps scopes per request. The consent POST does not
depend on a cookie: identity and CSRF ride the single-use consent token, so it
survives Safari/ITP cross-site cookie blocking.

### Content authoring (`POST /mcp`)

Lets an agent author course content on an instructor's behalf. Gated by
`MCP_MODE` (`off` / `read_only` / `read_write`); scopes are clamped to the
mode ceiling. The catalog holds **54 tools** — `MCPToolCatalog.live` in
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
