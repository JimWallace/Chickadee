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
- **Worker** — Daemon process. Pulls jobs, runs builds and tests in sandboxed
  subprocesses, reports structured results back to the API server.
- **Core** — Shared models and types. No Vapor dependency. Both APIServer and
  Worker depend on this.

Language-specific build/test logic lives in **runner scripts** under `Runners/`
(not in Swift). The Swift worker spawns these as subprocesses and parses their
JSON output. This means adding a new language never requires changes to Swift code.

Full project structure and component diagrams are in `docs/architecture.md`.

---

## Key Design Decisions

**Runner protocol over JUnit XML.** All language runners write a single JSON
document to stdout. The Swift worker parses this. Runners must never write
anything else to stdout — use stderr for diagnostics.

**Build failure lives at the collection level, not the test level.** If the
build fails, `buildStatus` is `"failed"` and `outcomes` is `[]`. There is no
`couldNotRun` state on individual test outcomes.

**Test outcomes have four states only:** `pass`, `fail`, `error`, `timeout`.

**Three test tiers:** `public` (shown immediately), `release` (hidden until
deadline), `secret` (never shown), `student` (student-written tests).

**Gamification fields are present from day one but nullable.** `score`,
`memoryUsageBytes`, `attemptNumber`, `isFirstPassSuccess` are in the schema
now so we never need a migration later. They can be null/zero until the
feature is built.

**Subprocess boundary for all language execution.** Swift never imports a JVM,
Python interpreter, or any language runtime. Everything goes through
`Process` + sandbox.

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

### BuildLanguage
```swift
enum BuildLanguage: String, Codable {
    case java
    case python
    // others added here as runners are written
}
```

### TestOutcome
Single test case result. All fields present from day one.
```swift
struct TestOutcome: Codable {
    let testName: String
    let testClass: String?          // nil for Python
    let tier: TestTier
    let status: TestOutcomeStatus
    let shortResult: String
    let longResult: String?
    let executionTimeMs: Int
    let memoryUsageBytes: Int?      // nullable until measured
    let score: Double?              // 0.0–1.0, nullable until partial credit built
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
    let runnerVersion: String
    let timestamp: Date
}
```

### TestSetupManifest
Replaces the original Java `test.properties` file. Stored as JSON inside the
instructor-uploaded test setup zip.

```json
{
  "schemaVersion": 1,
  "language": "java",
  "requiredFiles": ["src/Warmup.java"],
  "testSuites": [
    { "tier": "public",  "className": "PublicTests"  },
    { "tier": "release", "className": "ReleaseTests" },
    { "tier": "student", "className": "StudentTests" }
  ],
  "limits": {
    "timeLimitSeconds": 10,
    "memoryLimitMb": 256
  },
  "options": {
    "allowPartialCredit": false
  }
}
```

---

## Runner JSON Protocol

Every runner must write exactly this structure to stdout and nothing else.

```json
{
  "runnerVersion": "java-runner/1.0",
  "buildStatus": "passed",
  "compilerOutput": null,
  "executionTimeMs": 342,
  "outcomes": [
    {
      "testName": "testBitCount",
      "testClass": "PublicTests",
      "tier": "public",
      "status": "pass",
      "shortResult": "passed",
      "longResult": null,
      "executionTimeMs": 12,
      "memoryUsageBytes": null
    }
  ]
}
```

On build failure, `outcomes` is `[]` and `compilerOutput` contains the
compiler error text.

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

**Phase 1 — Core pipeline.**

Goals for this phase:
1. `Package.swift` with three targets: `Core`, `Worker`, `APIServer`
2. All `Core/` models with full `Codable` conformances and unit tests
3. `RunnerResult` — the Swift type that maps from runner JSON output
4. `TestSetupManifest` parser
5. `JavaBuildStrategy` — spawns `Runners/java/run_tests.sh`, parses output
6. `WorkerDaemon` — basic loop, no sandbox yet
7. `POST /api/v1/worker/results` — accepts and stores a `TestOutcomeCollection`
8. End-to-end test: submit a zip manually, get a JSON result

Do not work ahead into Phase 2 (full API, test setup management) until
Phase 1 has a working end-to-end path.

---

## Phase Roadmap

| Phase | Focus |
|-------|-------|
| 1 | Core models, Java runner, basic worker loop, single result endpoint |
| 2 | Full REST API, test setup upload and storage, worker pull loop |
| 3 | Python runner and PythonBuildStrategy |
| 4 | Sandboxing (macOS first, then Linux) |
| 5 | Gamification — attempt tracking, leaderboards, partial credit |

---

## What Not To Do

- Do not add a database dependency in Phase 1. Write results to disk as JSON.
- Do not implement sandboxing in Phase 1.
- Do not add authentication in Phase 1.
- Do not import Vapor in `Core/`.
- Do not parse JUnit XML. The Java runner handles that internally and emits
  the canonical JSON protocol.
- Do not use `ObjectOutputStream` or any Java serialization format anywhere.
- Do not add `CouldNotRun` as a `TestOutcomeStatus`. Build failures are
  represented at the collection level.

---

## Reference Material

- `docs/architecture.md` — full architecture document with diagrams
- `reference/` — original Java source for behavioural reference only
