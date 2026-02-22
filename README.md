<img src="Assets/chickadee-icon-alt.png" alt="Chickadee mascot" width="160" align="right">

# Chickadee

A clean-break rewrite of [Marmoset](https://marmoset.cs.umd.edu), the student code submission and autograding system. Written in Swift using [Vapor](https://vapor.codes), targeting macOS and Linux.

---

## What it does

Chickadee accepts student code submissions, runs instructor-defined test suites, and returns structured JSON results. Test suites are plain shell scripts — no language-specific code paths exist in Swift. Adding support for a new language or framework means writing a new shell script; no Swift changes are required.

Gamification fields (attempt tracking, leaderboards, partial credit) are present in the schema from day one so they never require a migration.

---

## Architecture

Three Swift targets share a clean dependency boundary:

```
┌─────────────────────────────────────────┐
│             chickadee-server            │
│  REST API (Vapor) + Leaf web UI         │
└──────────────────┬──────────────────────┘
                   │  SQLite (Fluent)
┌──────────────────▼──────────────────────┐
│             chickadee-runner            │
│  Polls for jobs → ScriptRunner          │
│  Reports TestOutcomeCollection to API   │
└──────────────────┬──────────────────────┘
                   │  subprocess (sandboxed)
        ┌──────────┴──────────┐
        ▼                     ▼
  test_public.sh        test_release.sh
  (instructor-written shell scripts)
```

**Core** — shared models with no Vapor dependency. Both targets depend on this.

**Shell scripts, not language runners.** Each test suite is a `.sh` file at the root of the instructor's test-setup zip. The runner executes them with `/bin/sh` and maps the exit code to a result. Any helper library (Python, Java, etc.) is bundled inside the zip by the instructor.

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
│   ├── APIServer/     # Vapor app, REST routes, Fluent migrations, Leaf UI
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
swift run chickadee-server
```

Run the worker, pointing it at a running API server:

```bash
swift run chickadee-runner \
  --api-base-url http://localhost:8080 \
  --worker-id    worker-1 \
  --max-jobs     4

# With sandboxing enabled (recommended for production):
swift run chickadee-runner \
  --api-base-url http://localhost:8080 \
  --worker-id    worker-1 \
  --sandbox
```

`swift run` is a development convenience that builds and runs in one step. For production, build a release binary once and invoke it directly — no Swift toolchain is needed at runtime:

```bash
swift build -c release
.build/release/chickadee-server
.build/release/chickadee-runner --api-base-url http://api:8080 --worker-id w1 --sandbox
```

## JupyterLite rebuilds

`Public/jupyterlite` is generated output. The source-of-truth config and version pins live in:

- `Tools/jupyterlite/jupyter-lite.json`
- `Tools/jupyterlite/requirements.txt`

Rebuild commands:

```bash
scripts/setup-jupyterlite.sh
scripts/build-jupyterlite.sh
```

The build script keeps runtime notebook storage directories (`Public/jupyterlite/files`, `Public/jupyterlite/lab/files`, `Public/jupyterlite/notebooks/files`) while refreshing generated assets.

---

## Component docs

| Component | README |
|-----------|--------|
| Core (shared models) | [Sources/Core/README.md](Sources/Core/README.md) |
| chickadee-server (API + web UI) | [Sources/APIServer/README.md](Sources/APIServer/README.md) |
| chickadee-runner (worker) | [Sources/Worker/README.md](Sources/Worker/README.md) |

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
