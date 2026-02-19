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
│  POST /api/v1/worker/request            │
│  POST /api/v1/worker/results            │
│  POST /api/v1/testsetups                │
└──────────────────┬──────────────────────┘
                   │  job queue
┌──────────────────▼──────────────────────┐
│               Worker                    │
│  Pulls jobs → BuildStrategy → sandbox   │
│  Reports TestOutcomeCollection to API   │
└──────────────────┬──────────────────────┘
                   │  subprocess + sandbox
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
| Concurrency | `async/await`, actors, structured task groups |
| Test runners | pytest (Python), nbmake (Jupyter Notebook) |
| Sandboxing | `sandbox-exec` (macOS), seccomp + user namespaces (Linux) |
| Build tool | Swift Package Manager |

---

## Project structure

```
Chickadee/
├── Sources/
│   ├── Core/          # Shared models — Codable, Sendable, no Vapor
│   ├── APIServer/     # Vapor app and REST routes
│   └── Worker/        # Job poller, build strategies, sandbox
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

Requires Swift 5.9+ ([swift.org](https://swift.org/download)) and Xcode 15+ on macOS.

```bash
swift build
swift test
```

Run the Worker CLI directly against a local submission (Phase 1):

```bash
swift run Worker \
  --submission path/to/submission.zip \
  --testsetup  path/to/testsetup/ \
  --runners-dir Runners/
```

Run the API server:

```bash
swift run APIServer
```

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

On build failure, `buildStatus` is `"failed"`, `compilerOutput` contains the compiler error, and `outcomes` is `[]`. There is no per-test "could not run" state.

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
| 1 | Core models, Worker CLI stub, `POST /results` | Complete |
| 2 | Full REST API, test setup upload, Worker pull loop | Up next |
| 3 | Python and Jupyter runners, `PythonBuildStrategy`, `JupyterBuildStrategy` | Planned |
| 4 | Sandboxing — macOS first, then Linux | Planned |
| 5 | Gamification — attempt tracking, leaderboards, partial credit | Planned |

---

## License

MIT — see [LICENSE](LICENSE).
