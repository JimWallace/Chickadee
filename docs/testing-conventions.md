# Testing conventions

The rules for Swift and JavaScript tests, with the reason for each. CLAUDE.md
keeps the short form and points here.

- **Framework: Swift Testing only.** Every Swift test (plus the `.mjs`
  frontend tests in `Tests/BrowserRunnerJSTests/`, run by `node --test`) has
  been on Swift Testing since the migration completed (PRs #597–#608). `scripts/no-new-xctest.sh`
  blocks any new `import XCTest` under `Tests/`. The nightly
  `test-coverage.yml` run measures line coverage over all four targets
  (87 % on 2026-09-20) against an 80 % floor.
- **Approved Swift Testing vocabulary.** `@Suite`, `@Test`, `#expect`,
  `#require`, `.serialized`, `.tags(...)`, `.enabled(if:)` / `.enabled { }` /
  `.disabled(if:)`, `@Test(arguments:)`, `#expect(processExitsWith:)` (an exit
  test: the body runs in a child process, for a path that ends the process or
  writes process-global state such as `setenv` — see
  `WedgeWatchdogAbortTests` and the WorkerTests env tests; the body cannot
  capture `self`, so the helpers it calls are static or file-scope), and
  `.timeLimit(.minutes(n))` (put it on any suite
  that spawns subprocesses or awaits daemons/network, so a stall fails
  with a named test instead of holding the CI job to its 20-minute kill —
  see the #1139 postmortem in `docs/ci-flakiness.md`). Avoid
  `CustomExecutionTrait`, hand-rolled trait types, and anything still
  labelled experimental in the Swift Testing source — the API is still
  evolving.
- **Struct vs class suites.**
  - **`@Suite struct Foo`** — default. Per-test instance is cheap.
  - **`@Suite final class Foo`** with `init()` / `deinit` — when the
    suite needs expensive shared state per-test instance (temp
    directories, Vapor app fixtures). For Vapor apps, store `let app`
    and wrap each `@Test` body in `try await withApp(app) { _ in ... }`
    so teardown is deterministic (`withApp` runs the full
    `tearDownTestApp`: shutdown plus removal of the app's temp
    directories and sqlite-kit's fake-memory database file — #1298);
    the next test's `init` builds a fresh app.
- **`with*App` helpers** for DB-backed suite clusters
  (`withWebRoutesApp`, `withAssignmentRoutesApp`, `withPatternFamilyFixture`).
  See `Tests/APITests/WebRoutesHelpers.swift` etc. for the pattern.
- **`.serialized` on DB- or env-touching suites.** Swift Testing runs
  tests in parallel within a suite by default; `.serialized` gates
  within-suite parallelism. For cross-suite serialization (e.g. tests
  that mutate process env vars), use the actor-backed
  `withAsyncEnvLock { ... }` in `Tests/APITests/EnvTestLock.swift` or
  `withMockURLProtocolLock { ... }` in
  `Tests/WorkerTests/Support/WorkerTestSkip.swift`.
- **No force unwraps in tests.** The corpus cleanup finished in the 0.5
  pass — `Tests/.swiftlint.yml` no longer exempts `!` / `try!` / `as!`
  (its only remaining relaxation is `type_body_length`). Use
  `try #require(value)` — the idiomatic Swift Testing replacement for
  `XCTUnwrap`.
- **Skipping a test at runtime.** Don't use `Issue.record` to skip — it
  records a failure. A condition the host may not meet (an interpreter on
  PATH, a Python module, CI itself) is a `ConditionTrait` on the test:
  `@Test(.requiresLua)`, `@Test(.ciOnly)`, `@Test(.requiresRscript)`, each a
  `static let` built with `.enabled("requires lua on PATH") { … }`. The
  traits more than one file needs live in one `HostConditionTraits.swift` per
  test target (`WorkerTestSkip.swift` in WorkerTests): `.ciOnly` and one
  `.requires…` per interpreter or tool (`Rscript`, `Octave`, `Gpp`, `Javac`,
  `Racket`, `Lua`, `Python3`, `ZipTools`, `Sandbox`, `Make`). Add a new one
  there, not in a suite. The probes behind them
  (`cachedToolIsAvailable`) are in `ChickadeeTestSupport`, which also holds
  `IssueRecorded` and `testURL` for all three targets. Swift Testing then
  reports the test as skipped with that reason, in the log and in the xUnit report, and
  `scripts/check-no-skipped-tests.sh` fails every CI test lane on any skip,
  because the CI image carries every interpreter. That closed the silent-skip
  trap: a `guard condition else { return }` kept a lane green having executed
  nothing in a language, three times. The guard form survives only where a
  trait cannot express the condition — per-argument availability in a
  parameterized test, or a body whose first half runs without the tool — and
  each such site says so in a comment. "Test setup is broken" is still
  `throw IssueRecorded("...")`, which fails with a clear message.
- **Pattern references.**
  - Standalone struct suite:
    [Tests/APITests/COEPMiddlewareTests.swift](../Tests/APITests/COEPMiddlewareTests.swift)
  - Class suite with sync `init`/`deinit`:
    [Tests/APITests/ZipArchiverTests.swift](../Tests/APITests/ZipArchiverTests.swift)
  - Class suite with stored `app` + per-test `withApp`:
    [Tests/APITests/AdminRoutesTests.swift](../Tests/APITests/AdminRoutesTests.swift)
  - `with*App` helper-driven suite:
    [Tests/APITests/WebRoutesIndexTests.swift](../Tests/APITests/WebRoutesIndexTests.swift)
  - Parameterized + `try #require`:
    [Tests/APITests/MCP/MCPModeScopeContractTests.swift](../Tests/APITests/MCP/MCPModeScopeContractTests.swift)
  - Worker-side class suite:
    [Tests/WorkerTests/DirectorySizeBytesTests.swift](../Tests/WorkerTests/DirectorySizeBytesTests.swift)
