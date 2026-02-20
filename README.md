<img src="Assets/chickadee-icon-alt.png" alt="Chickadee mascot" width="160" align="right">

# Chickadee

A clean-break rewrite of [Marmoset](https://marmoset.student.cs.uwaterloo.ca/), the student code submission and autograding system. Written in Swift using [Vapor](https://vapor.codes), targeting macOS and Linux.

---

## What it does

Chickadee accepts student code submissions, builds them, runs instructor-defined test suites, and returns structured JSON results. It is designed from the ground up to support gamification features (attempt tracking, partial credit, leaderboards) without requiring a schema migration later.

---

## Architecture

Three Swift targets share a clean dependency boundary:

```
┌─────────────────────────────────────────┐
│             APIServer (Vapor)           │
│  POST /api/v1/submissions               │
│  POST /api/v1/worker/request            │
│  POST /api/v1/worker/results            │
│  POST /api/v1/testsetups                │
│  GET  /api/v1/testsetups/:id/download   │
│  GET  /api/v1/submissions/:id/download  │
└──────────────────┬──────────────────────┘
                   │  SQLite (Fluent)
┌──────────────────▼──────────────────────┐
│               Worker                    │
│  Polls for jobs → BuildStrategy         │
│  Reports TestOutcomeCollection to API   │
└──────────────────┬──────────────────────┘
                   │  subprocess
        ┌──────────┴──────────┐
        ▼                     ▼
  Runners/python/       Runners/jupyter/
  run_tests.py          run_tests.py
  (emit JSON)           (emit JSON)
```

**Core** — shared models with no Vapor dependency. Both APIServer and Worker depend on this.

**Language-specific logic lives entirely in runner scripts.** The Swift worker spawns them as subprocesses and parses their JSON output. Adding a new language means writing a new runner script, not touching Swift.

---

## Tech stack

| Layer | Technology |
|-------|-----------|
| Language | Swift 6 (strict concurrency) |
| Web framework | Vapor 4 |
| Database | SQLite via Fluent |
| Concurrency | `async/await`, actors, structured task groups |
| Test runners | pytest (Python), nbmake (Jupyter Notebook) |
| Sandboxing | `sandbox-exec` (macOS), seccomp + user namespaces (Linux) — Phase 4 |
| Build tool | Swift Package Manager |

---

## Project structure

```
Chickadee/
├── Sources/
│   ├── Core/          # Shared models — Codable, Sendable, no Vapor
│   ├── APIServer/     # Vapor app, REST routes, Fluent migrations
│   └── Worker/        # Job poller, build strategies, worker daemon
├── Runners/
│   ├── python/        # run_tests.py (pytest wrapper)
│   └── jupyter/       # run_tests.py (nbmake wrapper)
├── Tests/
│   ├── CoreTests/     # Round-trip JSON encode/decode for all models
│   ├── APITests/      # XCTVapor integration tests
│   └── WorkerTests/   # Worker unit tests
└── Assets/            # Project icons
```

---

## Building

Requires Swift 6 ([swift.org](https://swift.org/download)) and Xcode 16+ on macOS.

```bash
swift build
swift test
```

Run the API server:

```bash
swift run APIServer
```

Run the Worker, pointing it at a running API server:

```bash
swift run Worker \
  --api-base-url http://localhost:8080 \
  --worker-id    worker-1 \
  --max-jobs     4 \
  --runners-dir  Runners/
```

---

## REST API

Base path: `/api/v1`

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/submissions` | Submit a zip for grading (base-64 encoded) |
| `GET`  | `/submissions/:id/download` | Download a submission zip |
| `POST` | `/worker/request` | Worker claims the next pending job |
| `POST` | `/worker/results` | Worker reports a completed `TestOutcomeCollection` |
| `POST` | `/testsetups` | Instructor uploads a test setup (multipart) |
| `GET`  | `/testsetups/:id/download` | Download a test-setup zip |

---

## Runner protocol

Every language runner writes a single JSON document to stdout when it finishes. Nothing else goes to stdout — diagnostics use stderr.

```json
{
  "runnerVersion": "python-runner/1.0",
  "buildStatus": "passed",
  "compilerOutput": null,
  "executionTimeMs": 342,
  "outcomes": [
    {
      "testName": "test_bit_count",
      "testClass": null,
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

On build failure, `buildStatus` is `"failed"`, `compilerOutput` contains the error, and `outcomes` is `[]`. There is no per-test "could not run" state.

---

## Test setup manifest

Stored as JSON inside the test-setup zip uploaded by the instructor. Replaces the legacy `test.properties` file.

```json
{
  "schemaVersion": 1,
  "language": "python",
  "requiredFiles": ["warmup.py"],
  "testSuites": [
    { "tier": "public",  "module": "test_public"  },
    { "tier": "release", "module": "test_release" }
  ],
  "limits": {
    "timeLimitSeconds": 10
  }
}
```

For Jupyter Notebook submissions, `module` is the `.ipynb` filename.

---

## Test tiers

| Tier | Shown to student |
|------|-----------------|
| `public` | Immediately after submission |
| `release` | On demand; hidden until deadline passes |
| `secret` | Never |
| `student` | Student-written tests, always visible |

---

## Phase status

| Phase | Focus | Status |
|-------|-------|--------|
| 1 | Core models, `RunnerResult`, `TestSetupManifest`, `POST /results` stub | Complete |
| 2 | Full REST API, SQLite persistence, Worker pull loop | Complete |
| 3 | Python and Jupyter runners, `run_tests.py` scripts | Up next |
| 4 | Sandboxing — macOS first, then Linux | Planned |
| 5 | Gamification — attempt tracking, leaderboards, partial credit | Planned |

---

## License

MIT — see [LICENSE](LICENSE).
