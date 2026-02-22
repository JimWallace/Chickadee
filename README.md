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

## Building

Requires Swift 6 ([swift.org](https://swift.org/download)) and Xcode 16+ on macOS.

```bash
swift build
swift test
```

Run the API server:

```bash
swift run chickadee-server serve --port 8080 --worker-secret your-secret
```

Run the runner, pointing it at a running API server:

```bash
swift run chickadee-runner \
  --api-base-url http://localhost:8080 \
  --worker-id    worker-1 \
  --worker-secret your-secret \
  --max-jobs     4

# With sandboxing enabled (recommended for production):
swift run chickadee-runner \
  --api-base-url http://localhost:8080 \
  --worker-id    worker-1 \
  --worker-secret your-secret \
  --sandbox
```

`swift run` is a development convenience that builds and runs in one step. For production, build a release binary once and invoke it directly — no Swift toolchain is needed at runtime:

```bash
swift build -c release
.build/release/chickadee-server serve --port 8080 --worker-secret your-secret
.build/release/chickadee-runner --api-base-url http://api:8080 --worker-id runner-1 --worker-secret your-secret --sandbox
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

## License

MIT — see [LICENSE](LICENSE).
