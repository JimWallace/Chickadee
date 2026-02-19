# Marmoset Swift Rewrite — Architecture Document

## Overview

This document defines the architecture for a clean-break rewrite of the Marmoset build/test server in Swift using Vapor. The system accepts student code submissions, builds them, runs instructor-defined test suites, and returns structured results. The design is intentionally extensible to support gamification features in future iterations.

---

## Core Principles

- **Language-agnostic at the core.** The Swift server knows nothing about JUnit, pytest, or any specific test framework. All language knowledge lives in runner scripts.
- **Structured results everywhere.** Every test run produces a JSON outcome document. No parsing of stdout, no pass/fail inferred from exit codes.
- **Simple first, extensible always.** Fields needed for gamification are present in the schema from day one, but can be null/zero until the feature is built.
- **Clean subprocess boundary.** The Swift worker spawns isolated processes for builds and tests. Sandboxing is applied at that boundary uniformly across all languages.

---

## System Components

```
┌─────────────────────────────────────────────────────────┐
│                      API Server                         │
│                    (Vapor app)                          │
│  POST /submissions/request                              │
│  GET  /testsetup/:id                                    │
│  POST /results/report                                   │
└────────────────────────┬────────────────────────────────┘
                         │  Job Queue (DB-backed)
┌────────────────────────▼────────────────────────────────┐
│                       Worker                            │
│               (WorkerDaemon.swift)                      │
│  Pulls jobs → dispatches to BuildStrategy               │
│  Captures structured JSON result                        │
│  Reports back to API Server                             │
└────────────────────────┬────────────────────────────────┘
                         │  subprocess + sandbox
          ┌──────────────┴──────────────┐
          ▼                             ▼
   Runners/java/                 Runners/python/
   run_tests.sh                  run_tests.py
   (compiles + runs,             (runs pytest,
    emits JSON)                   emits JSON)
```

---

## Project Structure

```
MarmosetSwift/
├── Sources/
│   ├── APIServer/
│   │   ├── APIServerApp.swift
│   │   ├── Routes/
│   │   │   ├── SubmissionRoutes.swift
│   │   │   ├── TestSetupRoutes.swift
│   │   │   └── ResultRoutes.swift
│   │   └── Models/
│   │       ├── APISubmission.swift
│   │       └── APITestSetup.swift
│   │
│   ├── Worker/
│   │   ├── WorkerDaemon.swift
│   │   ├── JobPoller.swift
│   │   ├── Sandbox/
│   │   │   ├── Sandbox.swift            (protocol)
│   │   │   ├── LinuxSandbox.swift       (seccomp + namespaces)
│   │   │   └── MacOSSandbox.swift       (sandbox-exec)
│   │   └── Strategies/
│   │       ├── BuildStrategy.swift      (protocol)
│   │       ├── JavaBuildStrategy.swift
│   │       └── PythonBuildStrategy.swift
│   │
│   └── Core/
│       ├── Models/
│       │   ├── TestOutcome.swift
│       │   ├── TestOutcomeCollection.swift
│       │   ├── TestTier.swift
│       │   ├── TestOutcomeStatus.swift
│       │   └── BuildLanguage.swift
│       ├── TestSetupManifest.swift      (replaces test.properties)
│       └── RunnerResult.swift           (JSON from runner scripts)
│
├── Runners/
│   ├── java/
│   │   ├── run_tests.sh
│   │   └── junit_runner/               (thin Java shim that emits JSON)
│   │       └── MarmosetRunner.java
│   └── python/
│       └── run_tests.py
│
├── Tests/
│   ├── CoreTests/
│   ├── WorkerTests/
│   └── APITests/
│
└── Package.swift
```

---

## Data Models

### TestOutcomeStatus

The exhaustive set of states a single test case can be in.

```swift
// Core/Models/TestOutcomeStatus.swift

enum TestOutcomeStatus: String, Codable {
    case pass            // Test ran and all assertions passed
    case fail            // Test ran and an assertion failed
    case error           // Test ran but threw an unexpected exception/crash
    case timeout         // Test exceeded the time limit
    // Note: "Could Not Run" is represented at the collection level
    // (buildOutcome == .failed), not at the individual test level.
    // Individual tests are only recorded if the build succeeded.
}
```

### TestTier

```swift
// Core/Models/TestTier.swift

enum TestTier: String, Codable {
    case pub        // "public"   — results shown to student immediately
    case release    // "release"  — run on demand, hidden until deadline
    case secret     // "secret"   — never shown to student
    case student    // "student"  — student-written tests, run for their benefit
}
```

### TestOutcome

The complete record for a single test case execution. Fields marked
`// gamification` are present from day one but can be null/zero until needed.

```swift
// Core/Models/TestOutcome.swift

struct TestOutcome: Codable {

    // --- Identity ---
    let testName: String           // e.g. "testBitCount"
    let testClass: String?         // e.g. "PublicTests" (nil for Python)
    let tier: TestTier

    // --- Result ---
    let status: TestOutcomeStatus
    let shortResult: String        // One-line human-readable summary
    let longResult: String?        // Full output, stack trace, diff, etc.

    // --- Performance ---
    let executionTimeMs: Int
    let memoryUsageBytes: Int?     // gamification — null if not measured yet

    // --- Gamification (future-ready, nullable now) ---
    let score: Double?             // 0.0–1.0 for partial credit; null = binary
    let attemptNumber: Int         // Which attempt this was (starts at 1)
    let isFirstPassSuccess: Bool   // true if passed on attempt 1
}
```

### TestOutcomeCollection

The complete result for one submission run.

```swift
// Core/Models/TestOutcomeCollection.swift

struct TestOutcomeCollection: Codable {

    // --- Submission identity ---
    let submissionID: String
    let testSetupID: String
    let attemptNumber: Int

    // --- Build ---
    let buildStatus: BuildStatus
    let compilerOutput: String?    // nil if build succeeded

    // --- Test outcomes ---
    // Empty if buildStatus == .failed
    let outcomes: [TestOutcome]

    // --- Aggregate stats (derived, stored for query convenience) ---
    let totalTests: Int
    let passCount: Int
    let failCount: Int
    let errorCount: Int
    let timeoutCount: Int
    let executionTimeMs: Int       // wall time for the full run

    // --- Metadata ---
    let runnerVersion: String      // e.g. "java-runner/1.0"
    let timestamp: Date
}

enum BuildStatus: String, Codable {
    case passed
    case failed
    case skipped   // e.g. download-only mode during development
}
```

---

## Test Setup Manifest

Replaces `test.properties`. Stored as JSON inside the test setup zip uploaded by the instructor.

```json
{
  "schemaVersion": 1,
  "language": "java",
  "requiredFiles": [
    "src/Warmup.java"
  ],
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

For Python:

```json
{
  "schemaVersion": 1,
  "language": "python",
  "requiredFiles": [
    "warmup.py"
  ],
  "testSuites": [
    { "tier": "public",  "module": "test_public"  },
    { "tier": "release", "module": "test_release" }
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

Every language runner — regardless of implementation — must write a single JSON
document to stdout when it finishes. The Swift worker parses this document and
maps it into `TestOutcomeCollection`. The runner must never write anything else
to stdout (use stderr for diagnostic output).

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
    },
    {
      "testName": "testFirstDigitIntegerMinValue",
      "testClass": "ReleaseTests",
      "tier": "release",
      "status": "fail",
      "shortResult": "expected:<2> but was:<8>",
      "longResult": "junit.framework.AssertionFailedError: expected:<2> but was:<8>\n\tat ReleaseTests.testFirstDigitIntegerMinValue(ReleaseTests.java:45)",
      "executionTimeMs": 8,
      "memoryUsageBytes": null
    },
    {
      "testName": "testIsOddForPositiveNumbers",
      "testClass": "ReleaseTests",
      "tier": "release",
      "status": "timeout",
      "shortResult": "Exceeded time limit of 10s",
      "longResult": null,
      "executionTimeMs": 10000,
      "memoryUsageBytes": null
    }
  ]
}
```

If the build fails, outcomes is an empty array:

```json
{
  "runnerVersion": "java-runner/1.0",
  "buildStatus": "failed",
  "compilerOutput": "Warmup.java:12: error: ';' expected\n        return x % 2 != 0\n                         ^\n1 error",
  "executionTimeMs": 0,
  "outcomes": []
}
```

---

## BuildStrategy Protocol

```swift
// Worker/Strategies/BuildStrategy.swift

protocol BuildStrategy {
    var language: BuildLanguage { get }

    /// Validate that the runner environment is available
    /// (e.g. javac is on PATH). Called once at startup.
    func preflight() async throws

    /// Run the full build + test cycle for a submission.
    /// Returns the parsed RunnerResult.
    func run(
        submission: URL,
        testSetup: URL,
        manifest: TestSetupManifest,
        sandbox: any Sandbox
    ) async throws -> RunnerResult
}
```

---

## REST API

All endpoints accept and return `application/json`.

### Request a submission to build

```
POST /api/v1/worker/request

Request:
{
  "workerID": "worker-1",
  "supportedLanguages": ["java", "python"],
  "hostname": "buildserver-01.example.com"
}

Response 200 — work available:
{
  "submissionID": "sub_abc123",
  "testSetupID":  "setup_xyz789",
  "submissionURL": "https://.../submissions/sub_abc123/download",
  "testSetupURL":  "https://.../testsetups/setup_xyz789/download"
}

Response 204 — no work available
```

### Report results

```
POST /api/v1/worker/results

Body: TestOutcomeCollection (full JSON object as defined above)

Response 200:
{
  "received": true
}
```

### Upload a test setup (instructor-facing)

```
POST /api/v1/testsetups

Multipart form:
  manifest: (JSON, as defined above)
  files:    (zip of test source files)

Response 201:
{
  "testSetupID": "setup_xyz789"
}
```

---

## Worker Loop

Replaces the hand-rolled `doOneRequest` poll loop. Uses Swift structured
concurrency throughout.

```swift
// Worker/WorkerDaemon.swift

actor WorkerDaemon {
    func run() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<maxConcurrentJobs {
                group.addTask { try await self.workerLoop() }
            }
            try await group.waitForAll()
        }
    }

    private func workerLoop() async throws {
        var backoff = ExponentialBackoff(initial: .seconds(1), max: .seconds(30))
        while true {
            if let job = try await poller.requestJob() {
                backoff.reset()
                try await process(job)
            } else {
                try await Task.sleep(for: backoff.next())
            }
        }
    }

    private func process(_ job: Job) async throws {
        let strategy = try strategyFor(job.manifest.language)
        let result   = try await strategy.run(
            submission: job.submissionURL,
            testSetup:  job.testSetupURL,
            manifest:   job.manifest,
            sandbox:    sandbox
        )
        let collection = TestOutcomeCollection(from: result, job: job)
        try await reporter.report(collection)
    }
}
```

---

## Sandboxing

Applied uniformly at the subprocess boundary, regardless of language.

| Platform | Mechanism                        | What it restricts                         |
|----------|----------------------------------|-------------------------------------------|
| Linux    | `seccomp` + user namespaces      | Syscalls, filesystem, network, PID space  |
| macOS    | `sandbox-exec` with profile      | Filesystem, network, process spawning     |

Both implementations conform to the same protocol:

```swift
// Worker/Sandbox/Sandbox.swift

protocol Sandbox {
    /// Wrap a Process with sandbox constraints before launching.
    func apply(to process: inout Process, workDir: URL, limits: ResourceLimits) throws
}

struct ResourceLimits {
    let timeLimitSeconds: Int
    let memoryLimitMb: Int
}
```

---

## Phased Delivery Plan

### Phase 1 — Core pipeline (start here)
- `Core/` models and JSON codable conformances
- Java runner script (compile + JUnit 3/4/5, emit JSON)
- `JavaBuildStrategy` + `WorkerDaemon` (no sandbox yet)
- `POST /api/v1/worker/results` endpoint only (store to disk/DB)
- End-to-end test: submit a zip, get a JSON result

### Phase 2 — API + test setup management
- Full REST API (all three endpoints)
- Test setup upload, storage, and retrieval
- Worker pull loop talking to API server

### Phase 3 — Python support
- Python runner (`run_tests.py` using pytest)
- `PythonBuildStrategy`
- Manifest updates for Python-specific fields

### Phase 4 — Sandboxing
- `MacOSSandbox` (develop on macOS first)
- `LinuxSandbox` (deploy target)
- Resource limit enforcement (timeout, memory)

### Phase 5 — Gamification hooks
- Attempt tracking per student per assignment
- `isFirstPassSuccess` calculation
- Score/partial credit support in manifest + runner protocol
- Leaderboard-ready aggregate endpoints

---

## Key Design Decisions

**Why not `CouldNotRun` as a test outcome status?**
Build failure is represented at the collection level (`buildStatus: "failed"`,
`outcomes: []`). Individual test outcomes only exist if the build succeeded.
This avoids a meaningless state on every test case and makes the data model
cleaner to query.

**Why store `attemptNumber` and `isFirstPassSuccess` from day one?**
These require knowing submission history at record time. Retrofitting them later
means either a migration or recalculating from historical data. Writing them at
insert time is trivial and costs nothing.

**Why a subprocess boundary for runners?**
It allows adding new languages without touching Swift code, applies sandboxing
uniformly, and means a crashing test can never take down the worker process.
The cost is process-spawn overhead (~50ms), which is negligible compared to
compile and test execution time.

**Why JSON for the runner protocol and not JUnit XML?**
JUnit XML is a de facto standard but it carries JUnit-specific concepts
(test suites as classes, failures as assertion errors) that don't map cleanly
to other languages or non-unit-test scenarios. A custom JSON schema lets the
protocol evolve with the system's needs.
