# Chickadee — Project Context

## What This Is

A clean-break rewrite of Marmoset, a student code submission and autograding
system originally built in Java at the University of Maryland. The rewrite is
in Swift using Vapor, targeting both macOS and Linux (containerized deployment
later). No interoperability with the original Java system is required.

The original Java codebase is available for reference in `/reference/` if
needed, but the architecture has been redesigned from scratch.

---

## Architecture Overview

Three Swift targets share a clean dependency boundary:

- **`chickadee-server`** — Vapor app. REST API + Leaf web UI. Handles auth,
  assignment management, submission intake, result storage, and the JupyterLite
  notebook workflow.
- **`chickadee-runner`** — Daemon process. Polls for jobs, runs shell-script
  test suites in subprocesses (sandboxed or unsandboxed), reports structured
  results back to the server.
- **`Core`** — Shared models and types. No Vapor dependency. Both targets
  depend on this.

Test suites are **shell scripts** bundled by the instructor inside the test
setup zip. The runner executes them generically — no language-specific code
paths exist in Swift. Adding a new language means writing a new shell script;
no Swift changes are required.

---

## Key Design Decisions

**Shell scripts, not language runners.** Each test suite is a `.sh` file at the
root of the instructor's test setup zip. The runner runs them with `/bin/sh`
and maps the exit code to a result status. No per-language runners, no runner
JSON protocol.

**Instructor bundles the helper library.** Any helper library (Swift, Python,
etc.) is included in the test setup zip by the instructor. The runner does not
inject anything.

**Build failure lives at the collection level, not the test level.** If the
build fails (e.g. `make` step fails), `buildStatus` is `"failed"` and
`outcomes` is `[]`. There is no `couldNotRun` state on individual test outcomes.

**Test outcomes have four states only:** `pass`, `fail`, `error`, `timeout`.

**Four test tiers:** `public` (shown immediately), `release` (hidden until
deadline), `secret` (never shown), `student` (student-written tests).

**Gamification fields are present from day one but nullable.** `memoryUsageBytes`,
`attemptNumber`, `isFirstPassSuccess` are in the schema now so we never need a
migration later. They can be null/zero until the feature is built.

**`ScriptRunner` is the sandbox boundary.** `UnsandboxedScriptRunner` is the
default in development. `SandboxedScriptRunner` implements the same protocol
using platform sandboxing (macOS: `sandbox-exec`; Linux: `unshare` user/net
namespaces). Enable with `--sandbox` on the runner.

**Subprocess boundary for all language execution.** Swift never imports a JVM,
Python interpreter, or any language runtime. Everything goes through
`Process` + sandbox.

**Three user roles.** `student`, `instructor`, `admin`. Role is stored on
`APIUser` and enforced via `RoleMiddleware`. Admin implies instructor.

**Auth is pluggable.** `AUTH_MODE` env var selects `.local` (username/password),
`.sso` (future OIDC/OAuth), or `.dual` (both). `APIUser` carries
`authProvider` + `externalSubject` for SSO identity. Currently only `.local`
is implemented; the model is forward-compatible.

**HTTPS enforcement is optional and proxy-aware.** `AppSecurityConfiguration`
reads `ENFORCE_HTTPS`, `PUBLIC_BASE_URL`, `TRUST_X_FORWARDED_PROTO`, and
`SESSION_COOKIE_SECURE`. `HTTPSRedirectMiddleware` handles the enforcement and
respects `X-Forwarded-Proto` from reverse proxies.

**Worker secret is auto-generated.** If no secret is provided at startup, a
random three-word diceware passphrase is generated from the EFF wordlist and
persisted to `.worker-secret`. The runner reads it from `RUNNER_SHARED_SECRET`.
All runner↔server requests are HMAC-signed (`WorkerHMACAuthMiddleware`).

**Local runner autostart.** The server can spawn a `chickadee-runner` subprocess
automatically if `.local-runner-autostart` exists (or is toggled via the admin
dashboard). This is a development convenience; production runs the runner
separately.

---

## Test Script Contract

Each test suite is a shell script run with `/bin/sh <script>` from the test
setup directory as the working directory.

| Exit code | Meaning |
|-----------|---------|
| 0 | pass |
| 1 | fail |
| 2 | error |
| killed (SIGKILL after timeout) | timeout |

**stdout:** Everything is ignored except the last non-empty line, which is
attempted as JSON:
```json
{ "score": 0.75, "shortResult": "3/4 cases passed" }
```
If the last line is not valid JSON, it is used as the plain-text `shortResult`.
If stdout is empty, `shortResult` is synthesized from the exit code
("passed" / "failed" / "error"). `score` is reserved for partial credit
(not yet used).

**stderr:** Captured verbatim as `longResult` (nil if empty).

---

## Data Models (Core/)

### TestOutcomeStatus
```swift
enum TestOutcomeStatus: String, Codable {
    case pass, fail, error, timeout
}
```

### TestTier
```swift
enum TestTier: String, Codable {
    case pub       // "public"
    case release
    case secret
    case student
}
```

### TestOutcome
Single test case result.
```swift
struct TestOutcome: Codable {
    let testName: String
    let testClass: String?          // always nil (shell scripts have no class)
    let tier: TestTier
    let status: TestOutcomeStatus
    let shortResult: String
    let longResult: String?
    let executionTimeMs: Int
    let memoryUsageBytes: Int?      // nullable until measured
    let attemptNumber: Int
    let isFirstPassSuccess: Bool
}
```

### TestOutcomeCollection
Complete result for one submission run.
```swift
struct TestOutcomeCollection: Codable {
    let submissionID: String
    let testSetupID: String
    let attemptNumber: Int
    let buildStatus: BuildStatus
    let compilerOutput: String?
    let outcomes: [TestOutcome]
    let totalTests: Int
    let passCount: Int
    let failCount: Int
    let errorCount: Int
    let timeoutCount: Int
    let executionTimeMs: Int
    let runnerVersion: String       // "shell-runner/1.0"
    let timestamp: Date
}
```

### TestProperties
Stored as `test.properties.json` inside the instructor-uploaded test setup zip.

```json
{
  "schemaVersion": 1,
  "requiredFiles": ["warmup.py"],
  "testSuites": [
    { "tier": "public",  "script": "test_bit_count.sh"  },
    { "tier": "release", "script": "test_first_digit.sh" },
    { "tier": "student", "script": "test_student.sh" }
  ],
  "timeLimitSeconds": 10,
  "makefile": null
}
```

`makefile` is optional. When present, a `make` step runs before the test
scripts. If `target` is `null`, bare `make` is invoked; otherwise
`make <target>` is used.

---

## REST API

Base path: `/api/v1`

```
# Runner endpoints (HMAC-signed)
POST /worker/request                    — Runner polls for a pending job
POST /worker/results                    — Runner reports TestOutcomeCollection
GET  /worker/artifacts/:submissionID    — Runner downloads submission zip

# Test setups (instructor upload; download available to all authenticated users)
POST /api/v1/testsetups                 — Instructor uploads test setup zip (multipart)
GET  /api/v1/testsetups/:id/download    — Stream zip to runner

# Submissions
POST /api/v1/submissions                — Accept student submission zip
GET  /api/v1/submissions                — List submissions (?testSetupID= filter)
GET  /api/v1/submissions/:id            — Submission status
GET  /api/v1/submissions/:id/results    — Full TestOutcomeCollection (?tiers= filter)

# Web / browser results
GET  /results/:id                       — Browser-rendered result view
```

Web routes (Leaf-rendered, session auth required) live under `/` and handle
login, registration, the student dashboard, assignment pages, submission
history, instructor assignment CRUD, and the admin panel.

All JSON endpoints use `application/json`. The test setup upload is multipart.

---

## Auth & Roles

Three roles in ascending order of privilege: `student` < `instructor` < `admin`.

- **Unauthenticated:** login, register, runner endpoints (HMAC-signed separately)
- **Authenticated (any role):** web UI, submission queries, result views,
  JupyterLite content routes, notebook download
- **Instructor+:** assignment CRUD, submission intake, test setup management
- **Admin:** admin panel, worker secret/autostart management, runner dashboard

Session auth uses Vapor's `SessionAuthenticator`. Sessions are in-memory
(swap to `.fluent` for multi-process deployments). Session cookie is
`HttpOnly; SameSite=Lax`; `Secure` flag is set automatically when
`PUBLIC_BASE_URL` is `https://` or `AUTH_MODE` is non-local.

---

## JupyterLite

Chickadee embeds a full JupyterLite instance at `Public/jupyterlite/`. This
enables in-browser notebook editing for both students (submit) and instructors
(create/validate assignments).

Source-of-truth config lives in `Tools/jupyterlite/`. Rebuild:

```bash
scripts/setup-jupyterlite.sh
scripts/build-jupyterlite.sh
```

`Public/jupyterlite` is generated output and is checked in; rebuild only when
updating kernel versions or config.

---

## Coding Conventions

- Swift 6, strict concurrency. No `@unchecked Sendable` without a comment explaining why.
- `async/await` throughout. No completion handlers.
- Actors for any shared mutable state (`WorkerSecretStore`, `WorkerActivityStore`,
  `LocalRunnerAutoStartStore`, `LocalRunnerManager`).
- All models in `Core/` must be `Codable`, `Sendable`, and have no Vapor imports.
- Error types are explicit enums, not `String` or generic `Error` where avoidable.
- No force unwraps except in tests.
- Optionals are preferred over sentinel values (no `-1` for "missing").
- File names match the primary type they contain.
- One type per file unless the types are trivially small and closely related.

---

## Versioning

Follows Semantic Versioning in the `0.y.z` phase. Current version: **0.3.0**
(`VERSION` file + `ChickadeeVersion.current` in Core).

Release checklist:

```bash
# 1) Update VERSION, CHANGELOG.md
scripts/check-version.sh
swift test
# 2) Tag
git tag -a vX.Y.Z -m "Chickadee vX.Y.Z"
git push origin vX.Y.Z
```

---

## Current State

All phases through 8 are complete:

| Phase | Focus | Status |
|-------|-------|--------|
| 1 | Core models, basic runner loop, single result endpoint | ✓ |
| 2 | Full REST API, test setup upload, runner pull loop, shell-script runner | ✓ |
| 3 | Submission result retrieval API, student-facing endpoints | ✓ |
| 4 | Sandboxing (`SandboxedScriptRunner` — macOS `sandbox-exec`, Linux `unshare`) | ✓ |
| 5 | Browser-based notebook grading (Pyodide in-browser, inline feedback) | ✓ |
| 6 | Username/password auth, three roles, class management | ✓ |
| 7 | Instructor assignment management UI, grade export, submission summaries | ✓ |
| 8 | Instructor notebook editor (in-browser edit/save/validate via JupyterLite) | ✓ |

Post-8 work also complete:
- Worker HMAC auth, runner secret hardening
- Local runner autostart
- Short assignment IDs, retest actions
- AODA accessibility pass
- v0.1.0 schema hardening (canonical migrations, FK enforcement, WAL, performance indexes)
- HTTPS/SSO scaffolding (`AuthMode`, `AppSecurityConfiguration`, `HTTPSRedirectMiddleware`,
  `AddUserSSOFields` migration)
- v0.2.0 schema consolidation (all patch migrations folded into canonical `Create*` files;
  `course_id` NOT NULL with FK on `test_setups` and `assignments`)
- v0.3.0 admin course management UI (course detail, bulk CSV enroll, unenroll, archive)
- v0.3.0 course bundle export/import (`.chickadee` zip)
- v0.3.0 admin courses section rework (create/edit page consolidation)

**Next work:** SSO implementation (OIDC/OAuth provider integration), gamification
(attempt tracking, leaderboards), containerized deployment.

---

## What Not To Do

- Do not import Vapor in `Core/`.
- Do not add `CouldNotRun` as a `TestOutcomeStatus`. Build failures are
  represented at the collection level (`buildStatus: "failed"`).
- Do not write a runner JSON protocol — the runner interprets exit codes directly.
- Do not add per-language build strategies in Swift — test suites are plain shell scripts.
- Do not use `@unchecked Sendable` without a comment.

---

## Reference Material

- `docs/architecture.md` — full architecture document with diagrams
- `reference/` — original Java source for behavioural reference only
- `CHANGELOG.md` — release history
