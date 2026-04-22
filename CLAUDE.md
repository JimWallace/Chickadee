# Chickadee — Project Context

## What This Is

A clean-break rewrite of Marmoset, a student code submission and autograding
system originally built in Java at the University of Maryland. The rewrite is
in Swift using Vapor, targeting both macOS and Linux. No interoperability with
the original Java system is required.

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
setup zip. The runner executes them generically. Adding a new language means
writing a new shell script; no Swift changes are required for the *grading*
path. The runner does include Python/notebook-specific submission normalization
(`SubmissionNormalizer`, `NotebookExtractor`) that pre-processes uploads before
handing them to the shell scripts.

---

## Key Design Decisions

**Shell scripts, not language runners.** Each test suite is a `.sh` file at the
root of the instructor's test setup zip. The runner runs them with `/bin/sh`
and maps the exit code to a result status. No per-language runners, no runner
JSON protocol. The runner does contain a Python/notebook normalization layer
(`SubmissionNormalizer`) that pre-processes uploaded files into a grading
workspace before the shell scripts run. This is a submission-format concern,
not a grading concern — the shell scripts themselves remain language-agnostic.

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
`.sso` (OIDC/OAuth), or `.dual` (both active simultaneously). `APIUser` carries
`authProvider` + `externalSubject` for SSO identity. Both `.local` and `.sso`
are fully implemented. The OIDC flow uses Authorization Code + PKCE; the
discovery document and JWKS are fetched at startup from `OIDC_AUTH_SERVER`.
Role assignment uses `SSO_ADMIN_USERS` / `SSO_INSTRUCTOR_USERS` env vars
(comma-separated identity allowlists checked against JWT claims on every login).
The current implementation is tested against UWaterloo DUO; claim names
(`winaccountname`, `user_id`) are in `OIDCIDTokenClaims.swift` and can be
adjusted for other providers.

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

**Pattern-generated test families (v0.4.75+).** Instructors can define a
`PatternFamily` (Core/) — one function, shared defaults, a table of cases —
and Chickadee expands each enabled case into an ordinary Python test script
at save time. Families live in `TestProperties.patternFamilies`; generated
entries in `testSuites` carry `generatedBy: <familyID>` so the raw-script edit
endpoints refuse to mutate them (you edit the family instead). Two kinds
ship: `.boundaryEquality` (single-arg equality) and `.approximateEquality`
(float tolerance, v0.4.80). Generated filenames are deterministic
(`{tier}test_{familyID}_{caseKey}.py`) and embed a `spec_hash` header so
manifest bytes change when any case changes.

**Server-authoritative suite editor (v0.4.79+).** The instructor assignment
edit page is wired to `PUT /instructor/:assignmentID/suite` and
`PUT /instructor/:assignmentID/families` — drag-reorder, tier/points edits,
and family edits persist live with the server returning the reconciled state.
The legacy client-side `#suite-config-field` JSON blob and the
`/edit/save` suite-rebuild path are gone; the main Save button only handles
name, due date, notebook uploads, and the validation enqueue. Dependencies
accept `family:<id>` tokens which the server expands to concrete filenames
before persistence; cycle detection runs on the authored graph.

**Assignment vanity URLs (v0.4.71).** Each assignment gets a per-course
unique slug. Student links prefer `/:courseCode/:assignmentSlug` routes while
the canonical `/testsetups/:id/submit` handlers remain active for
compatibility.

**Runner-side LRU test setup cache (v0.4.41).** `TestSetupCache` (Swift actor,
default 16 entries) keeps fully-prepared test setup directories keyed by
`testSetupID`. Cache key hashes manifest + zip content, so any suite edit
busts the entry. Concurrent jobs for the same setup share one in-flight
population task.

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
    { "tier": "release", "script": "test_first_digit.sh",
      "dependsOn": ["family:bmi"] },
    { "tier": "public",  "script": "publictest_bmi_01.py",
      "generatedBy": "bmi" },
    { "tier": "student", "script": "test_student.sh" }
  ],
  "patternFamilies": [
    {
      "id": "bmi",
      "function": "classify_bmi",
      "kind": "boundaryEquality",
      "defaults": { "tier": "public", "points": 1 },
      "cases": [
        { "key": "01", "args": [18.49], "expected": "underweight" }
      ]
    }
  ],
  "timeLimitSeconds": 10,
  "makefile": null
}
```

`makefile` is optional. When present, a `make` step runs before the test
scripts. If `target` is `null`, bare `make` is invoked; otherwise
`make <target>` is used.

`patternFamilies` is the canonical spec for generated test families; each
enabled case expands to a `testSuites` entry with `generatedBy: <familyID>`.
`dependsOn` entries in authored form accept `family:<id>` tokens, which the
server expands to the family's concrete generated filenames before
persisting.

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

# Instructor suite editor (server-authoritative, v0.4.79+)
GET  /instructor/:assignmentID/suite    — Author-facing view of the ordered suite list
PUT  /instructor/:assignmentID/suite    — Persist drag-reorder, tier/points/displayName edits
PUT  /instructor/:assignmentID/families — Save a pattern family (add/edit/delete)
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

Session auth uses Vapor's `SessionAuthenticator`. Sessions are persisted
via the Fluent driver (v0.4.46), so they survive restarts and work across
multi-process deployments. Session cookie is `HttpOnly; SameSite=Lax`; `Secure`
flag is set automatically when `PUBLIC_BASE_URL` is `https://` or `AUTH_MODE`
is non-local.

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

Follows Semantic Versioning in the `0.y.z` phase. Current version: **0.4.82**
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
- SSO/OIDC implementation (Authorization Code + PKCE, dual mode, role assignment via
  allowlists, tested against UWaterloo DUO)
- v0.4.0 test dependency trees (`dependsOn` in manifest, tree UI, runner pre-check)
- v0.4.0 Docker Compose deployment (`Dockerfile`, `docker-compose.yml`, entrypoint,
  nginx config, updated `deploy/README.md`)
- v0.4.1 zip-slip guard, security headers, CSRF integration test infrastructure
- v0.4.2 browser-runner enrollment gate, submission error message hardening
- v0.4.5 test coverage expansion (334 tests total); `WebRoutes.swift` split into
  `WebContextTypes`, `WebRoutes+Notebook`, `WebRoutes+Submission`
- v0.4.7–0.4.11 notebook/assignment edit round-trip fixes; multipart save hardening;
  Linux worker timeout hardening; browser/WASM runner CI coverage
- v0.4.12–0.4.16 submission result display polish (test names, traceback extraction,
  JSON blob cleanup); notebook cache busting; assignment editor display-name persistence
- v0.4.17–0.4.18 concurrent worker claim race fixed (`WorkerClaimQueue` eager init);
  Marmoset import missing-notebook and `starterNotebook` overwrite bugs fixed
- v0.4.19 `WorkerClaimQueue` converted to Swift actor; admin dashboard queries parallelized
- v0.4.20 `ScriptRunner` timeout converted to structured `Task`; `ZipArchiver` drops
  `DispatchQueue` bridge; domain-specific error types (`NotebookLookupError`, `WorkerJobError`)
- v0.4.22 `ExponentialBackoff` zero-delay fix; `Reporter.report()` retry logic added
- v0.4.23 runner advertises its version on every poll (`runnerVersion` field)
- v0.4.24 Safari autofill bypass for admin credential inputs
- v0.4.25 admin runner dashboard: version, load, avg run/wait columns; runner advertises
  `maxConcurrentJobs`; `submission_diagnostics` table now populated
- v0.4.26 admin runner table JS poll fixed (columns were reverting after 5-second refresh)
- v0.4.30 runner-side Python submission normalization (MIME detection, notebook extraction,
  submission warnings surfaced in results)
- v0.4.32 unique Docker runner IDs; compact sparkline charts; reconnect hardening;
  HTTP retry classification improved (408, 425, 429, 500 now retryable)
- v0.4.33 poll-loop retry backoff now honors `RUNNER_RETRY_*` env settings
- v0.4.34 instructor student submission drilldown; course-scoped student submissions page
- v0.4.36 submission IDs on runner detail page are clickable; UI consistency pass
- v0.4.37 architecture docs (`docs/architecture.md`); SSO token revocation on logout
  (RFC 7009 + `end_session_endpoint` redirect); configurable OIDC claim names
  (`OIDC_USERNAME_CLAIM`, `OIDC_EMAIL_CLAIM`, flexible `extraClaims`); large source
  splits (`RunnerDaemon.swift`, `AdminRoutes.swift`, `AssignmentRoutes.swift`)
- v0.4.38 Python test bootstrap now sets `sys.argv[0]` correctly; `chickadee.py`
  exit 3 maps to `fail`; `NotebookExtractor` wraps bare module-level code in
  `if __name__ == "__main__":` and strips IPython `%`/`!` lines to prevent
  import-time failures
- v0.4.39–v0.4.44 OIDC claim generalization follow-ups (compile fixes, test
  coverage for custom-claim first-login, stale-username repair, `user_id` not
  clobbered by username claim, Docker Compose env forwarding)
- v0.4.41 runner-side LRU test setup cache (`TestSetupCache` actor, content-hashed
  cache key, shared in-flight population)
- v0.4.45 re-test wait time measured from retest click (`retested_at` column,
  `queueWaitMs`/`turnaroundMs` baseline switched)
- v0.4.46 Fluent-backed sessions (survive restarts, multi-process safe);
  automatic cache-buster from `ChickadeeVersion.current`; runner stage timing
  metrics (`job_execution_metrics`) persisted and surfaced on runner detail
- v0.4.47 poll-time 401/403 treated as retryable so long-lived runners recover
  from transient auth windows
- v0.4.48 instructor dashboard activity cards (recent logins, submissions,
  active assignments, queued attempts, no-submission students); assignment
  summary cards; drag thumb beside assignment name
- v0.4.49 browser-mode guard: `runner-submit` rejects browser-graded setups
  server-side; instructor queue card counts only worker-eligible submissions
- v0.4.50 draft-backed notebook authoring on new-assignment page (hidden
  drafts, JupyterLite launch, reopen-for-edit, finalize); runner requirements
  auto-detected and pre-filled during creation
- v0.4.51 First-Try Perfect badge (100% first submission); submission output
  table redesigned (pass-only collapsible, diagnostics in full-width rows)
- v0.4.52 automated deadline auto-close (startup sweep + periodic runtime
  sweep, late-submission guard across web/browser endpoints, instructor
  manual-reopen override); GitHub release workflow
- v0.4.56 worker backstop for browser-graded submissions (native `python3`
  grades stuck browser-mode jobs, matching Pyodide semantics)
- v0.4.57 JSON footer stripped from student-visible test output;
  `:latest` Docker tag now pushed on version tag releases
- v0.4.58 create-assignment page redesigned to match edit page
  (compact `results-table` layout, editable display names, CodeMirror 6
  modal, inline runner requirements)
- v0.4.60 notebook sync preserves unsaved edits; submit button disabled until
  notebook loaded; worker queue depth excludes browser-graded submissions
- v0.4.61 syntax errors in student submissions now surfaced in `longResult`
  with full traceback
- v0.4.63 notebook upload draft endpoint wiring fixed for Safari; admin user
  Delete button
- v0.4.67 raw submission filenames sanitized before storage/runner staging;
  empty draft-only notebook upload parts ignored on validation
- v0.4.69–v0.4.70 student action icons (edit/upload); submit page uses
  assignment title
- v0.4.71 stable per-course assignment slugs; student dashboard links prefer
  `/:courseCode/:assignmentSlug` routes
- v0.4.72 new-script validation uses active manifest-backed suite; setup
  download version includes manifest+zip metadata hash
- v0.4.73 generated/uploaded tests persist from visible suite list;
  extensionless Python scripts with shebang dispatched as Python
- v0.4.75 pattern-generated test families (#375): `PatternFamily`,
  `PatternCase`, `PatternKind` in Core; `.boundaryEquality` v1 template;
  deterministic filenames + `spec_hash` header; raw-script endpoints return
  409 on generated entries
- v0.4.76 pattern family editor UX redesign (rows inside Test Suite table,
  function dropdown from scanned notebook, auto-generated case keys,
  typed per-parameter columns)
- v0.4.77 pattern families survive assignment Save (manifest rebuild forwards
  `patternFamilies` and re-runs `applyPatternFamilies`); each generated case
  produces a distinct `TestOutcome`
- v0.4.78 pattern family cells accept bare-typed values (numbers, booleans,
  null, arrays/objects, bare strings); family rows stay visible during
  client-side suite-list rebuild
- v0.4.79 assignment suite editor unified around server-authoritative model:
  `PUT /instructor/:assignmentID/suite`, `GET /instructor/:assignmentID/suite`,
  `family:<id>` dependency tokens, authored-graph cycle detection.
  `#suite-config-field` hidden input and `/edit/save` suite-rebuild path removed
- v0.4.80 `.approximateEquality` pattern kind (float tolerance, default 1e-6,
  failure messages include delta); editable Pts on family rows; authored
  order preserved through `topologicallySorted`
- v0.4.81 pattern family row visual polish (matches script rows); Visibility
  column is an inline `<select>`; family row position survives modal save
  (legacy `applyPatternFamilies` now reconstructs authored ordering); suite
  edits re-trigger validation (debounced by pending-submission check)
- v0.4.82 due-date timezone fix across five display sites (all now use
  `waterlooDateTimeFormatter()` / `America/Toronto`, matching the edit form);
  `.form--wide` modifier so the assignment edit, new-assignment, and submit
  pages use the full 900px `.main` width instead of the 620px `.form` cap;
  `TestProperties.runnerSanitized()` strips `patternFamilies` from the `Job`
  payload so older runners don't crash decoding new `PatternKind` cases;
  `StuckSubmissionReaperMonitor` reclaims `assigned` submissions whose
  `assigned_at` is older than 10 minutes (startup sweep + 60 s periodic,
  registered via `StuckSubmissionReaperLifecycleHandler`)

**Next work:** Gamification expansion (leaderboards, more badges beyond
First-Try Perfect); multi-provider SSO testing beyond UWaterloo DUO; pattern
kinds beyond `.boundaryEquality` / `.approximateEquality` (e.g. property-based,
exception-expected); refresh token handling.

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

- `docs/architecture.md` — system architecture: targets, grading pipeline, auth, sandboxing, deployment
- `docs/operational-diagnostics.md` — observability tables, structured log events, metrics endpoint, ops runbook
- `docs/runner-capability-profiles.md` — runner capability matching, assignment requirements, rollout rules
- `docs/ci-followups.md` — CI reshaping notes from v0.4.6; WorkerTests gate status
- `reference/` — original Java source for behavioural reference only
- `CHANGELOG.md` — release history
