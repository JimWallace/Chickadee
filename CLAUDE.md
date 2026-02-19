# Marmoset Swift — Project Context

## What This Is

A clean-break rewrite of Marmoset, a student code submission and autograding
system originally built in Java at the University of Maryland. The rewrite is
in Swift using Vapor, targeting both macOS and Linux (containerized deployment
later). No interoperability with the original Java system is required.

The original Java codebase is available for reference in `/reference/` if
needed, but the architecture has been redesigned from scratch.

---

## Architecture Overview

Three components, each in its own Swift target:

- **APIServer** — Vapor app. Exposes REST endpoints for workers and instructors.
- **Worker** — Daemon process. Pulls jobs, runs shell-script test suites in
  subprocesses, reports structured results back to the API server.
- **Core** — Shared models and types. No Vapor dependency. Both APIServer and
  Worker depend on this.

Test suites are **shell scripts** bundled by the instructor inside the test
setup zip. The Swift worker runs each script generically — no language-specific
code paths exist. Adding a new language means writing a new shell script; no
Swift changes are required.

Full project structure and component diagrams are in `docs/architecture.md`.

---

## Key Design Decisions

**Shell scripts, not language runners.** Each test suite is a `.sh` file at the
root of the instructor's test setup zip. The worker runs them with `/bin/sh`
and interprets the exit code. No per-language runners, no runner JSON protocol.

**Instructor bundles the helper library.** Any helper library (Swift, Python,
etc.) is included in the test setup zip by the instructor. The worker does not
inject anything.

**Build failure lives at the collection level, not the test level.** If the
build fails (e.g. `make` step fails), `buildStatus` is `"failed"` and
`outcomes` is `[]`. There is no `couldNotRun` state on individual test outcomes.

**Test outcomes have four states only:** `pass`, `fail`, `error`, `timeout`.

**Three test tiers:** `public` (shown immediately), `release` (hidden until
deadline), `secret` (never shown), `student` (student-written tests).

**Gamification fields are present from day one but nullable.** `memoryUsageBytes`,
`attemptNumber`, `isFirstPassSuccess` are in the schema now so we never need a
migration later. They can be null/zero until the feature is built. No partial
credit — `score` is not used.

**`ScriptRunner` is the sandbox boundary.** `UnsandboxedScriptRunner` is used
in Phase 1. Phase 4 adds `SandboxedScriptRunner` implementing the same protocol
without changing any callers.

**Subprocess boundary for all language execution.** Swift never imports a JVM,
Python interpreter, or any language runtime. Everything goes through
`Process` + sandbox.

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
("passed" / "failed" / "error"). `score` is reserved for Phase 5 (partial
credit) and ignored for now.

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
Single test case result. All fields present from day one.
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
POST /worker/request    — Worker pulls a job
POST /worker/results    — Worker reports results
POST /testsetups        — Instructor uploads a test setup (multipart)
```

All endpoints use `application/json` except the multipart upload.

---

## Coding Conventions

- Swift 6, strict concurrency. No `@unchecked Sendable` without a comment explaining why.
- `async/await` throughout. No completion handlers.
- Actors for any shared mutable state in the worker.
- All models in `Core/` must be `Codable`, `Sendable`, and have no Vapor imports.
- Error types are explicit enums, not `String` or generic `Error` where avoidable.
- No force unwraps except in tests.
- `@CheckForNull` / optionals are preferred over sentinel values (no `-1` for "missing").
- File names match the primary type they contain.
- One type per file unless the types are trivially small and closely related.

---

## Current Phase

**Phase 2 — Full REST API and worker pull loop.**

Goals for this phase:
1. `POST /api/v1/testsetups` — multipart upload, store zip + manifest in DB ✓
2. `GET /api/v1/testsetups/:id/download` — stream zip to worker ✓
3. `POST /api/v1/submissions` — accept student submission zip ✓
4. `POST /api/v1/worker/request` — worker polls for pending jobs ✓
5. `POST /api/v1/worker/results` — worker reports `TestOutcomeCollection` ✓
6. `WorkerDaemon` pull loop with exponential backoff ✓
7. `ScriptRunner` protocol + `UnsandboxedScriptRunner` ✓
8. End-to-end: upload test setup → submit code → worker runs scripts → results stored

---

## Phase Roadmap

| Phase | Focus |
|-------|-------|
| 1 | Core models, basic worker loop, single result endpoint |
| 2 | Full REST API, test setup upload and storage, worker pull loop, shell-script runner |
| 3 | Submission result retrieval API, student-facing endpoints |
| 4 | Sandboxing (macOS first via Sandbox profiles, then Linux) |
| 5 | Gamification — attempt tracking, leaderboards, partial credit |

---

## What Not To Do

- Do not implement sandboxing in Phase 1 or 2.
- Do not add authentication in Phase 1 or 2.
- Do not import Vapor in `Core/`.
- Do not add per-language build strategies — test suites are plain shell scripts.
- Do not add `CouldNotRun` as a `TestOutcomeStatus`. Build failures are
  represented at the collection level.
- Do not write a runner JSON protocol — the worker interprets exit codes directly.

---

## Reference Material

- `docs/architecture.md` — full architecture document with diagrams
- `reference/` — original Java source for behavioural reference only
