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

## Phase 6 — Web Frontend

Goal: a modern, lightweight website that replaces direct API calls for both
students submitting code and instructors managing assignments. The backend REST
API is the only interface; the frontend is a separate static app.

---

### 6.1 User Roles and Key Flows

**Student**
1. Open an assignment → drag-and-drop (or pick) a zip file → submit
2. Results appear automatically: public tests shown immediately, release tests
   hidden until the deadline passes
3. History view shows all prior attempts with trend (improving? regressing?)
4. Optional: leaderboard showing rank among classmates (pass count / score)

**Instructor**
1. Create a course and add assignments
2. Upload a test setup zip + fill out a short manifest form (no JSON editing)
3. Set deadline per assignment; release tests auto-unlock at that time
4. View a live roster: one row per student, color-coded by latest result
5. Drill into any student's full submission history and raw output

---

### 6.2 Page Inventory

```
/                           Landing / login
/dashboard                  Student: list of enrolled courses + assignments
/courses/:id                Course overview — assignment list with deadlines
/assignments/:id            Assignment page (submit + current result)
/assignments/:id/history    Student's full attempt history for one assignment
/assignments/:id/leaderboard Ranked list (pass count / score; public tier only)

/instructor                 Instructor dashboard — courses managed
/instructor/courses/new     Create course
/instructor/assignments/new Upload test setup + configure assignment
/instructor/assignments/:id Live roster — all students, latest results
/instructor/assignments/:id/student/:studentID  Full result drilldown
```

---

### 6.3 Screen Sketches

#### Assignment page — student view

```
┌─────────────────────────────────────────────────────────────┐
│ CS 101  /  Project 2 — Bit Manipulation          Due: Mar 5 │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │                                                       │  │
│  │     Drag your submission zip here, or click to pick  │  │
│  │                                                       │  │
│  └───────────────────────────────────────────────────────┘  │
│                              [Submit]                        │
│                                                             │
│  Latest result  (attempt 3 of 5)              ● 5 / 8 pass  │
│  ─────────────────────────────────────────────────────────  │
│  ✓  test_bit_count          passed          12 ms   public   │
│  ✓  test_clear_bit          passed           8 ms   public   │
│  ✗  test_set_bit            wrong answer    11 ms   public   │
│  ✗  test_toggle             wrong answer     9 ms   public   │
│  ✓  test_parity             passed          14 ms   public   │
│  ✗  test_count_ones         failed           8 ms   public   │
│  –  test_edge_cases         (hidden until deadline)          │
│  –  test_stress             (hidden until deadline)          │
│                                                             │
│  [View history]  [Leaderboard]                              │
└─────────────────────────────────────────────────────────────┘
```

#### Attempt history — student view

```
┌─────────────────────────────────────────────────────────────┐
│ Attempt history — Project 2                                 │
├────────┬───────────────┬──────────┬──────────┬─────────────┤
│ Attempt│ Submitted     │ Build    │ Public   │ Time        │
├────────┼───────────────┼──────────┼──────────┼─────────────┤
│   1    │ Feb 28 10:14  │ ✓ passed │ 2 / 6 ●● │ 0.3s        │
│   2    │ Feb 28 14:52  │ ✓ passed │ 4 / 6 ●●●│ 0.3s        │
│   3    │ Mar  1 09:07  │ ✓ passed │ 5 / 6 ●●●│ 0.3s  ← now │
├────────┴───────────────┴──────────┴──────────┴─────────────┤
│ [View full output for attempt 3 ▾]                          │
│  test_bit_count   passed   "passed"                         │
│  test_clear_bit   passed   "passed"                         │
│  test_set_bit     fail     "expected 0b1101, got 0b0101"    │
└─────────────────────────────────────────────────────────────┘
```

#### Live roster — instructor view

```
┌─────────────────────────────────────────────────────────────┐
│ Project 2 — Roster            45 students  [Export CSV]     │
├─────────────────────────────────────────────────────────────┤
│ Filter: [All ▾]  Search: [              ]                   │
├──────────────────┬──────────┬──────────┬────────┬───────────┤
│ Student          │ Attempts │ Best     │ Latest │ Updated   │
├──────────────────┼──────────┼──────────┼────────┼───────────┤
│ Alice Chen       │   3      │ 6 / 8  ● │ 5 / 8  │ 2h ago    │
│ Bob Smith        │   1      │ 8 / 8  ✓ │ 8 / 8  │ 5h ago    │
│ Carol Wang       │   0      │ —        │ —      │ —         │
│ Dan Lee          │   2      │ 3 / 8  ● │ 4 / 8  │ 1d ago    │
│   …              │          │          │        │           │
└──────────────────┴──────────┴──────────┴────────┴───────────┘
```

---

### 6.4 New API Endpoints Required

The frontend needs endpoints that don't yet exist. These become the Phase 6
backend work before (or alongside) the UI build.

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/api/v1/auth/login` | Exchange credentials for session token |
| `GET` | `/api/v1/courses` | List courses for current user |
| `POST` | `/api/v1/courses` | Create a course (instructor) |
| `GET` | `/api/v1/courses/:id/assignments` | List assignments in a course |
| `POST` | `/api/v1/courses/:id/assignments` | Create assignment (wraps test setup + deadline) |
| `GET` | `/api/v1/assignments/:id` | Assignment metadata (deadline, tier config) |
| `GET` | `/api/v1/assignments/:id/mysubmissions` | Current student's submission list |
| `GET` | `/api/v1/assignments/:id/roster` | All students + latest results (instructor) |
| `GET` | `/api/v1/assignments/:id/leaderboard` | Ranked list by pass count (public tier) |

**New data model additions** (database migrations):
- `courses` — `id`, `name`, `instructorID`, `createdAt`
- `assignments` — `id`, `courseID`, `testSetupID`, `deadline`, `name`, `releaseTestsAt`
- `users` — `id`, `name`, `email`, `role` (student | instructor), `passwordHash`
- `enrollments` — `courseID`, `userID` (join table)
- `submissions` gains `studentID` column

**Authentication:** session tokens in a `sessions` table; cookie-based for the
browser, Bearer token for the API. Phase 6.1 can use HTTP Basic for simplicity
and graduate to session tokens in 6.2.

**Tier visibility logic** moves server-side: the results endpoint checks
`now >= assignment.releaseTestsAt` before including `release` tier outcomes.
`secret` outcomes are never returned.

---

### 6.5 Tech Stack Recommendation

| Layer | Choice | Rationale |
|-------|--------|-----------|
| Framework | **SvelteKit** | Zero-runtime components, SSR by default, tiny bundle; simpler than Next.js for a focused tool |
| Styling | **Tailwind CSS** | Utility-first; avoids a design system dependency for a small UI surface |
| HTTP client | Native `fetch` + a thin typed wrapper | No axios; SvelteKit's `load()` functions handle server-side fetching naturally |
| Auth | Cookie sessions (server-side) | Simple to implement with SvelteKit's hooks; avoids client-side JWT complexity |
| Hosting | Static export to a CDN, or Vapor serves the built `/build` dir | One fewer service to operate in early deploys |
| Real-time updates | Polling `/api/v1/submissions/:id` every 2s while `status == "pending"` | Avoids WebSocket complexity; jobs typically finish in < 10s |

The frontend lives in a `Web/` directory at the repo root and is a separate
package (`package.json`). It talks exclusively to the Vapor API server; no
server-side logic lives in the frontend.

---

### 6.6 Phased Delivery

| Sub-phase | What ships |
|-----------|-----------|
| 6.1 | Auth (login/logout), student dashboard, submit + poll for results |
| 6.2 | Attempt history, result detail view, instructor roster |
| 6.3 | Leaderboard, CSV export, release-tier deadline unlock |
| 6.4 | Instructor assignment creation UI (replaces raw `curl` to `/testsetups`) |


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
