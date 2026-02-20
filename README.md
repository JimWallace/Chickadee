<img src="Assets/chickadee-icon-alt.png" alt="Chickadee mascot" width="160" align="right">

# Chickadee

A clean-break rewrite of [Marmoset](https://marmoset.student.cs.uwaterloo.ca/), the student code submission and autograding system. Written in Swift using [Vapor](https://vapor.codes), targeting macOS and Linux.

---

## What it does

Chickadee accepts student code submissions, runs instructor-defined test suites, and returns structured JSON results. Test suites are plain shell scripts — no language-specific code paths exist in Swift. Adding support for a new language or framework means writing a new shell script; no Swift changes are required.

Gamification fields (attempt tracking, leaderboards, partial credit) are present in the schema from day one so they never require a migration.

---

## Architecture

Three Swift targets share a clean dependency boundary:

```
┌─────────────────────────────────────────┐
│             APIServer (Vapor)           │
│  POST /api/v1/submissions               │
│  GET  /api/v1/submissions               │
│  GET  /api/v1/submissions/:id           │
│  GET  /api/v1/submissions/:id/results   │
│  POST /api/v1/worker/request            │
│  POST /api/v1/worker/results            │
│  POST /api/v1/testsetups                │
│  GET  /api/v1/testsetups/:id/download   │
└──────────────────┬──────────────────────┘
                   │  SQLite (Fluent)
┌──────────────────▼──────────────────────┐
│               Worker                    │
│  Polls for jobs → ScriptRunner          │
│  Reports TestOutcomeCollection to API   │
└──────────────────┬──────────────────────┘
                   │  subprocess (sandboxed)
        ┌──────────┴──────────┐
        ▼                     ▼
  test_public.sh        test_release.sh
  (instructor-written shell scripts)
```

**Core** — shared models with no Vapor dependency. Both APIServer and Worker depend on this.

**Shell scripts, not language runners.** Each test suite is a `.sh` file at the root of the instructor's test-setup zip. The worker runs them with `/bin/sh` and maps the exit code to a result. Any helper library (Python, Java, etc.) is bundled inside the zip by the instructor.

---

## Tech stack

| Layer | Technology |
|-------|-----------|
| Language | Swift 6 (strict concurrency) |
| Web framework | Vapor 4 |
| Database | SQLite via Fluent |
| Concurrency | `async/await`, actors, structured task groups |
| Test runners | Instructor-authored shell scripts |
| Sandboxing | `sandbox-exec` (macOS), `unshare --user --net` (Linux) |
| Build tool | Swift Package Manager |

---

## Project structure

```
Chickadee/
├── Sources/
│   ├── Core/          # Shared models — Codable, Sendable, no Vapor
│   ├── APIServer/     # Vapor app, REST routes, Fluent migrations
│   └── Worker/        # Job poller, script runner, worker daemon
├── Tests/
│   ├── CoreTests/     # Round-trip JSON encode/decode for all models
│   ├── APITests/      # XCTVapor integration tests
│   └── WorkerTests/   # ScriptRunner and worker unit tests
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
  --max-jobs     4

# With sandboxing enabled (recommended for production):
swift run Worker \
  --api-base-url http://localhost:8080 \
  --worker-id    worker-1 \
  --sandbox
```

---

## REST API

Base path: `/api/v1`

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/submissions` | Submit a zip for grading (base-64 encoded body) |
| `GET`  | `/submissions` | List submissions; optional `?testSetupID=` filter |
| `GET`  | `/submissions/:id` | Submission status (`pending`/`assigned`/`complete`/`failed`) |
| `GET`  | `/submissions/:id/results` | Full `TestOutcomeCollection`; optional `?tiers=public,student` filter |
| `POST` | `/worker/request` | Worker claims the next pending job |
| `POST` | `/worker/results` | Worker reports a completed `TestOutcomeCollection` |
| `POST` | `/testsetups` | Instructor uploads a test-setup zip (multipart) |
| `GET`  | `/testsetups/:id/download` | Download a test-setup zip |

---

## Test script contract

Each test suite is a shell script run as `/bin/sh <script>` from the test-setup directory as the working directory.

| Exit code | Meaning |
|-----------|---------|
| `0` | pass |
| `1` | fail |
| `2` | error |
| Killed after timeout | timeout |

**stdout:** Everything is ignored except the last non-empty line, which is attempted as JSON:

```json
{ "shortResult": "3/4 cases passed" }
```

If the last line is not valid JSON it is used as plain-text `shortResult`. If stdout is empty, `shortResult` is synthesised from the exit code.

**stderr:** Captured verbatim as `longResult` (nil if empty).

Build failure (e.g. a `make` step that exits non-zero) is recorded at the collection level — `buildStatus: "failed"`, `outcomes: []`. There is no per-test "could not run" state.

---

## Test setup manifest

Stored as `test.properties.json` inside the instructor-uploaded test-setup zip.

```json
{
  "schemaVersion": 1,
  "requiredFiles": ["warmup.py"],
  "testSuites": [
    { "tier": "public",  "script": "test_public.sh"  },
    { "tier": "release", "script": "test_release.sh" },
    { "tier": "student", "script": "test_student.sh" }
  ],
  "timeLimitSeconds": 10,
  "makefile": null
}
```

When `makefile` is non-null, a `make` step runs before the test scripts. Set `"target": null` for bare `make` or `"target": "test"` for `make test`.

---

## Test tiers

| Tier | Shown to student |
|------|-----------------|
| `public` | Immediately after submission |
| `release` | Hidden until deadline; unlocked on demand |
| `secret` | Never shown |
| `student` | Student-written tests, always visible |

The `GET /submissions/:id/results` endpoint accepts a `?tiers=` query parameter to filter which tiers are returned. Aggregate counts (`passCount`, `failCount`, etc.) are recomputed to match the filtered set.

---

## Sandboxing

`ScriptRunner` is the sandbox boundary. Two implementations exist:

- **`UnsandboxedScriptRunner`** — direct subprocess, no restrictions. Default when `--sandbox` is omitted. Suitable for development.
- **`SandboxedScriptRunner`** — wraps execution in an OS-level sandbox. Use `--sandbox` in production.

| Platform | Mechanism | What it restricts |
|----------|-----------|------------------|
| macOS | `sandbox-exec -p <profile>` | Network denied; writes confined to the working directory |
| Linux | `unshare --user --net --map-root-user` | Private network namespace (no external routes); UID mapped to unprivileged user inside the namespace |

Both implementations honour the same timeout, stdout/stderr capture, and exit-code mapping as the unsandboxed runner. No call sites change when switching between them.

---

## Phase status

| Phase | Focus | Status |
|-------|-------|--------|
| 1 | Core models, `ScriptRunner`, `POST /results` stub | Complete |
| 2 | Full REST API, SQLite persistence, worker pull loop, shell-script runner | Complete |
| 3 | Submission result retrieval — `GET /submissions`, `GET /submissions/:id`, `GET /submissions/:id/results` with tier filtering | Complete |
| 4 | Sandboxing — `SandboxedScriptRunner` with `sandbox-exec` (macOS) and `unshare` (Linux), `--sandbox` worker flag | Complete |
| 5 | Gamification — attempt tracking, leaderboards, partial credit | Up next |

---

## License

MIT — see [LICENSE](LICENSE).
