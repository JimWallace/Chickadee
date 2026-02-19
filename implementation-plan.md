# Chickadee — Implementation Plan

Based on `marmoset-swift-architecture.md`. Work proceeds in five phases; each
phase is independently shippable and leaves the system in a working state.

---

## Pre-work: Repository Scaffold

Before any phase begins, bootstrap the Swift package and CI skeleton.

**Tasks:**

1. `Package.swift` — declare four targets:
   - `Core` (library, no dependencies)
   - `APIServer` (executable, depends on Core + Vapor)
   - `Worker` (executable, depends on Core + Vapor for HTTP client)
   - `CoreTests`, `WorkerTests`, `APITests` (test targets)

2. Add `Vapor` and `swift-argument-parser` as package dependencies.

3. Add a minimal `Makefile` or shell script (`scripts/build.sh`) that runs
   `swift build` and `swift test`.

4. `.gitignore` for `.build/`, `.DS_Store`, `*.o`.

**Acceptance:** `swift build` succeeds with empty targets; `swift test` reports
zero tests run, zero failures.

---

## Phase 1 — Core Pipeline

Goal: end-to-end submission → JSON result on a single machine, no network, no
sandbox.

### 1.1 Core Models

Create each file below exactly as specified in the architecture document.

| File | Contents |
|------|----------|
| `Sources/Core/Models/TestOutcomeStatus.swift` | `enum TestOutcomeStatus: String, Codable` |
| `Sources/Core/Models/TestTier.swift` | `enum TestTier: String, Codable` |
| `Sources/Core/Models/BuildLanguage.swift` | `enum BuildLanguage: String, Codable` (java, python) |
| `Sources/Core/Models/TestOutcome.swift` | `struct TestOutcome: Codable` (all fields including gamification stubs) |
| `Sources/Core/Models/TestOutcomeCollection.swift` | `struct TestOutcomeCollection: Codable` + `enum BuildStatus` |
| `Sources/Core/TestSetupManifest.swift` | `struct TestSetupManifest: Codable` matching the JSON schema |
| `Sources/Core/RunnerResult.swift` | `struct RunnerResult: Codable` — the raw JSON produced by runner scripts |

**Notes on `TestSetupManifest`:**
- `testSuites` should use a polymorphic approach: a `TestSuiteEntry` struct
  with optional `className` (Java) and optional `module` (Python).
- `limits` → nested `struct ResourceLimits: Codable`.
- `options` → nested `struct ManifestOptions: Codable`.

**Notes on `RunnerResult`:**
- Mirrors the runner JSON protocol exactly (see architecture §Runner JSON Protocol).
- `outcomes` elements are `RunnerOutcome: Codable` — a flat struct without the
  gamification fields (those are added by the worker when constructing
  `TestOutcomeCollection`).

**Tests (`Tests/CoreTests/`):**
- Round-trip encode/decode for each model using `JSONEncoder`/`JSONDecoder`.
- Use the example JSON payloads from the architecture document as fixtures.
- Verify `buildStatus: "failed"` → `outcomes` is empty.

### 1.2 Java Runner

**Files:**

```
Runners/java/
├── run_tests.sh              # entry point called by WorkerDaemon
└── junit_runner/
    └── MarmosetRunner.java   # thin shim: runs JUnit, prints JSON to stdout
```

**`run_tests.sh` responsibilities:**
1. Accept arguments: `<submission_zip> <testsetup_dir> <manifest_json>`.
2. Unpack submission zip to a temp working directory.
3. Compile student source files + test class files using `javac`.
4. If compilation fails: print failure JSON to stdout and exit 0 (non-zero
   exit reserved for runner infrastructure errors only).
5. Invoke `MarmosetRunner` for each test suite listed in the manifest.
6. Collect per-suite JSON, merge into a single `RunnerResult` JSON, print to
   stdout.

**`MarmosetRunner.java` responsibilities:**
- Accept: test class name, tier string, time limit.
- Run JUnit 3/4/5 (detect dynamically using reflection).
- For each test: record name, status (pass/fail/error/timeout), timing,
  short result (assertion message or exception first line), long result (full
  stack trace).
- Print a JSON array of `RunnerOutcome` objects to stdout.
- All diagnostic output goes to stderr.

**Implementation notes:**
- Use JUnit Platform Launcher API (JUnit 5) as the primary runner; fall back to
  JUnit 4 `BlockJUnit4ClassRunner` and JUnit 3 `TestCase` detection via
  reflection.
- Timeout enforcement: run each test in a `Future` with `ExecutorService` and
  cancel after the time limit.
- Do not use any build tool (Maven, Gradle) inside the runner — compile with
  `javac` directly.

**Acceptance:** Given a valid `Warmup.java` submission, `run_tests.sh` produces
valid JSON matching the runner protocol. Given a file with a syntax error,
produces a `buildStatus: "failed"` JSON.

### 1.3 Worker (no sandbox)

**`Sources/Worker/Strategies/BuildStrategy.swift`** — protocol as specified.

**`Sources/Worker/Strategies/JavaBuildStrategy.swift`:**
- Implements `BuildStrategy`.
- `preflight()`: checks `javac` is on PATH; throws a descriptive error if not.
- `run(...)`: invokes `run_tests.sh` via `Foundation.Process`, captures stdout,
  decodes `RunnerResult`, returns it.
- Passes submission URL and test setup directory as arguments.
- Redirects stderr to a pipe for logging; does not mix it with stdout.

**`Sources/Worker/WorkerDaemon.swift`** (Phase 1 stub):
- No HTTP polling yet.
- `run(submissionZip: URL, testSetupDir: URL)` function that directly calls
  `JavaBuildStrategy.run(...)` and prints the resulting JSON to stdout.
- No concurrency beyond what `async/await` provides.

**Acceptance:** A command-line invocation
`swift run Worker --submission path/to/sub.zip --testsetup path/to/setup/`
prints a `TestOutcomeCollection` JSON to stdout.

### 1.4 Results Endpoint (stub API server)

**`Sources/APIServer/APIServerApp.swift`:** configure Vapor app.

**`Sources/APIServer/Routes/ResultRoutes.swift`:**
- `POST /api/v1/worker/results`
- Decode `TestOutcomeCollection` from body.
- Write to a JSON file on disk (keyed by `submissionID + timestamp`).
- Return `{"received": true}`.

**Acceptance:** `curl -X POST` with the fixture JSON returns `{"received":true}`
and a file appears on disk.

**Tests (`Tests/APITests/`):**
- Use Vapor's `XCTVapor` test utilities.
- POST the fixture JSON; assert 200 + `received: true`.
- Assert file was created on disk.

---

## Phase 2 — Full API + Worker Pull Loop

Goal: Worker pulls jobs from API server over HTTP; complete three-endpoint API.

### 2.1 Remaining API Endpoints

**`Sources/APIServer/Routes/SubmissionRoutes.swift`:**
- `POST /api/v1/worker/request` — find next pending submission matching
  worker's supported languages; return job or 204.
- Internal job state machine: `pending → assigned → complete/failed`.
- Store submissions and job state in a simple SQLite DB via Fluent
  (add `fluent-sqlite-driver` package dependency).

**`Sources/APIServer/Routes/TestSetupRoutes.swift`:**
- `POST /api/v1/testsetups` — multipart upload (manifest JSON + zip file).
- Validate manifest schema (schemaVersion, required fields).
- Store zip to disk; record metadata in DB.
- Return `{"testSetupID": "..."}`.
- `GET /api/v1/testsetups/:id/download` — stream zip to caller.

**`Sources/APIServer/Models/`:**
- `APISubmission.swift` — Fluent model for submissions table.
- `APITestSetup.swift` — Fluent model for test setups table.

**DB schema (Fluent migrations):**

```
submissions
  id          TEXT PRIMARY KEY
  testSetupID TEXT NOT NULL
  language    TEXT NOT NULL
  status      TEXT NOT NULL   -- pending, assigned, complete, failed
  workerID    TEXT
  submittedAt DATETIME
  assignedAt  DATETIME

test_setups
  id          TEXT PRIMARY KEY
  language    TEXT NOT NULL
  manifest    TEXT NOT NULL   -- JSON blob
  zipPath     TEXT NOT NULL
  createdAt   DATETIME

results
  id            TEXT PRIMARY KEY
  submissionID  TEXT NOT NULL
  collectionJSON TEXT NOT NULL   -- serialised TestOutcomeCollection
  receivedAt    DATETIME
```

### 2.2 Worker Pull Loop

**`Sources/Worker/JobPoller.swift`:**
- HTTP client (Vapor's `AsyncHTTPClient` or Swift's built-in `URLSession`).
- `requestJob() async throws -> Job?` — POST to `/api/v1/worker/request`,
  decode response or return `nil` on 204.

**`Sources/Worker/WorkerDaemon.swift`** (full version):
- Replace Phase 1 stub with the `actor WorkerDaemon` from the architecture doc.
- `ExponentialBackoff` helper struct: initial 1 s, max 30 s, reset on success.
- `maxConcurrentJobs` configurable via CLI flag (default 4).
- On receipt of a job: download submission zip and test setup zip to temp dirs,
  dispatch to `strategyFor(language)`, report result.

**`Sources/Worker/Reporter.swift`** (new):
- `POST /api/v1/worker/results` with the `TestOutcomeCollection`.

**Configuration (CLI flags for Worker executable):**
- `--api-base-url` — URL of API server.
- `--worker-id` — unique identifier for this worker instance.
- `--max-jobs` — concurrency limit.
- `--runners-dir` — path to the `Runners/` directory.

**Acceptance:**
- Start API server, start worker, upload a test setup, POST a submission; watch
  worker poll, process, and report result; query results endpoint; see
  `TestOutcomeCollection`.

---

## Phase 3 — Python Support

Goal: Python submissions processed end-to-end.

### 3.1 Python Runner

**`Runners/python/run_tests.py`:**
- Arguments: `<submission_zip> <testsetup_dir> <manifest_json>`.
- Unpack submission zip.
- Verify required files are present (from manifest).
- For each test suite in manifest, run `pytest <module>` with JSON output
  (`--json-report` plugin or parse pytest's built-in `-v` output).
- Map pytest outcomes to `RunnerOutcome` JSON.
- Print single `RunnerResult` JSON to stdout.
- Stderr for diagnostics.

**Timeout:** use `subprocess` with `timeout=` parameter for each suite.

**Notes:**
- Require `pytest` and `pytest-json-report` to be installed in the runner
  environment.
- `preflight()` in `PythonBuildStrategy` checks `python3 -m pytest --version`.

### 3.2 PythonBuildStrategy

**`Sources/Worker/Strategies/PythonBuildStrategy.swift`:**
- Same pattern as `JavaBuildStrategy`.
- Invokes `Runners/python/run_tests.py`.
- `preflight()` checks `python3` on PATH.

### 3.3 Manifest Updates

- `BuildLanguage` already includes `.python`; no schema changes needed.
- `TestSuiteEntry.module` (optional String) already accommodated.

**Acceptance:** A Python submission with a `warmup.py` file produces a valid
`TestOutcomeCollection` JSON with pytest results.

---

## Phase 4 — Sandboxing

Goal: runner subprocesses cannot escape their working directory, make network
calls, or consume unbounded resources.

### 4.1 Sandbox Protocol

**`Sources/Worker/Sandbox/Sandbox.swift`** — as specified in architecture doc.

### 4.2 macOS Sandbox (develop first)

**`Sources/Worker/Sandbox/MacOSSandbox.swift`:**
- Build a `sandbox-exec` profile string that:
  - Denies network access.
  - Allows read-only access to the JDK/Python runtime paths.
  - Allows read-write access to the working directory only.
  - Denies process spawning (no fork/exec beyond the runner itself).
- Apply by prepending `sandbox-exec -p <profile>` to the process launch.
- Timeout: wrap with `timeout(1)` command or set `process.terminationHandler`
  with a `DispatchWorkItem`.

**`ResourceLimits` enforcement:**
- Time limit: kill process group after `timeLimitSeconds`.
- Memory limit: on macOS, use `setrlimit(RLIMIT_AS, ...)` via `posix_spawn`
  attributes (requires a small C shim or inline assembly).

### 4.3 Linux Sandbox (deploy target)

**`Sources/Worker/Sandbox/LinuxSandbox.swift`:**
- User namespace: run subprocess as an unprivileged mapped UID.
- seccomp filter: allowlist of syscalls needed for Java/Python execution; deny
  `socket`, `bind`, `connect`, `openat` outside work dir.
- Implementation: write a small C helper (`Sources/CSandbox/`) that sets up
  namespaces and seccomp before exec; call it from Swift via SPM's C target
  support.
- Memory limit: `setrlimit(RLIMIT_AS, ...)` inside the namespace.
- Time limit: `SIGKILL` after deadline via `alarm(2)` or a watchdog task.

**`Sources/CSandbox/` (new C target in Package.swift):**
- `sandbox_helper.c` — sets up user namespace, writes uid_map/gid_map,
  applies seccomp BPF filter, then `execvp`s the runner.

**Acceptance:**
- Runner cannot open files outside workdir.
- Runner cannot make TCP connections.
- Runner is killed after time limit.
- Worker process survives a runner crash/OOM.

---

## Phase 5 — Gamification Hooks

Goal: populate `attemptNumber`, `isFirstPassSuccess`, and `score` fields in all
outcome records; expose aggregate endpoints for leaderboard use.

### 5.1 Attempt Tracking

- Add `(studentID, assignmentID)` to submission model.
- API server computes `attemptNumber` at submission intake time (count prior
  submissions for same student+assignment + 1).
- `isFirstPassSuccess` = `attemptNumber == 1 && outcome.status == .pass`.
- Both values written into `TestOutcomeCollection` at report time.

### 5.2 Partial Credit

- Manifest gains `"scoringMode": "binary" | "partial"`.
- Runner protocol gains optional `"score": 0.0–1.0` per outcome.
- Java runner maps `@Score` annotation (custom) or calculates from sub-tests.
- Python runner reads a `@pytest.mark.score(0.5)` marker.

### 5.3 Aggregate Endpoints

- `GET /api/v1/results/:submissionID` — return stored `TestOutcomeCollection`.
- `GET /api/v1/leaderboard/:assignmentID` — return top N students by pass
  count / score, filtered to `tier == pub`.
- `GET /api/v1/history/:studentID/:assignmentID` — attempt history.

---

## Testing Strategy

| Layer | Tool | When |
|-------|------|------|
| Core model encode/decode | `XCTest` | Phase 1 |
| Runner script output | Shell (`bats` or inline bash assert) | Phase 1 |
| API endpoints | `XCTVapor` | Phases 1, 2 |
| Worker integration | `XCTest` + local API server | Phase 2 |
| Sandbox escape attempts | Dedicated Linux test harness | Phase 4 |
| Gamification calculations | `XCTest` | Phase 5 |

All tests run on `swift test`. Runner script tests run via `swift test` by
invoking the shell scripts as subprocesses from within `WorkerTests`.

---

## Risk Register

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| JUnit 3/4/5 reflection is fragile | Medium | Pin JUnit Platform version; add fixture tests for each JUnit generation |
| seccomp allowlist too narrow (blocks legitimate syscalls) | High | Start with a permissive filter; tighten iteratively using `strace` logs |
| `sandbox-exec` profiles differ across macOS versions | Medium | Pin minimum macOS version; test on CI |
| Concurrent worker jobs exhaust temp disk space | Low | Enforce max-jobs ceiling; clean up temp dirs in `defer` blocks |
| Large submission zips cause memory pressure | Low | Stream-unzip; never load full zip into memory |

---

## File Creation Order (Phase 1 checklist)

```
[ ] Package.swift
[ ] Sources/Core/Models/TestOutcomeStatus.swift
[ ] Sources/Core/Models/TestTier.swift
[ ] Sources/Core/Models/BuildLanguage.swift
[ ] Sources/Core/Models/TestOutcome.swift
[ ] Sources/Core/Models/TestOutcomeCollection.swift
[ ] Sources/Core/TestSetupManifest.swift
[ ] Sources/Core/RunnerResult.swift
[ ] Tests/CoreTests/CoreModelTests.swift
[ ] Runners/java/junit_runner/MarmosetRunner.java
[ ] Runners/java/run_tests.sh
[ ] Sources/Worker/Strategies/BuildStrategy.swift
[ ] Sources/Worker/Strategies/JavaBuildStrategy.swift
[ ] Sources/Worker/WorkerDaemon.swift  (Phase 1 stub)
[ ] Sources/APIServer/APIServerApp.swift
[ ] Sources/APIServer/Routes/ResultRoutes.swift
[ ] Tests/APITests/ResultRoutesTests.swift
```
