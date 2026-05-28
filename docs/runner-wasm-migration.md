# Runner WASM Migration — one Swift grading core for both runners

Status: **in progress** (Stage 0 landed). Owner: see git history. This is the
authoritative plan; the staging here is what we execute against.

## Why

Chickadee grades submissions in two places:

- the **native worker** (`chickadee-runner`, Swift) — runs scripts in a
  subprocess under a sandbox;
- the **browser runner** (`Public/browser-runner.js`, JS + Pyodide) — runs the
  same scripts locally in the student's browser.

The browser runner is a **hand-written JS reimplementation of the worker's
logic**, and the two drift. Three production incidents in ~two weeks were all
this same shape:

1. extensionless-Python dispatch (the browser said "unsupported" while the
   worker ran it) — #754;
2. output-interpretation / dependency-skip wording parity — #755/#756;
3. `inspect.getsource`-based structural NotebookChecks fail in the browser
   because both runners `exec(compile())`-wrap notebook cells, so neither
   exposes real source (the HLTH-230 lab).

Cross-runner contract tests (Stage 0) catch drift, but they don't *remove* the
duplication, and they only catch what we thought to pin. The durable fix is to
have **one Swift implementation of all grading logic**, compiled to WebAssembly
so the browser runs the exact same code as the worker.

## The principle

Sort every browser-runner responsibility by one question: **does it have a
worker counterpart it could drift against?**

- **Has a worker twin → must be Swift, exactly once.** Notebook extraction,
  script dispatch, output interpretation, the suite-execution loop (dependency
  checks, skip messages, collection building). *This is the entire drift
  surface.*
- **No worker twin → may stay JS forever, no drift risk.** DOM glue (Submit
  button, status bar), loading Pyodide + the wasm module, fetching the test-setup
  zip, POSTing results. Nothing on the worker side for these to disagree with.
- **The one irreducible seam:** running Python — subprocess `python3` (worker)
  vs Pyodide (browser).

A fully JS-free browser is impossible: Pyodide's only contract is its JS API, and
two wasm modules in a browser communicate through the JS host. So Swift-in-wasm
*drives* Pyodide through JS (via JavaScriptKit). "Pure Swift" here means **all
logic is one Swift codebase**; JS shrinks to a thin bootstrap.

## End-state architecture

```
RunnerCore  (Swift · dependency-free · wasm-safe · the foundational leaf)
  • canonical runtime grading model: RunnerManifest, SuiteItem,
    TestOutcome, TestStatus, TestTier, ScriptOutput
  • shared logic: extract · classifyScript · interpretScriptOutput · executeSuites
  • protocol ScriptExecutor { run(script,kind,timeLimit) -> ScriptOutput; file I/O }

NativeScriptExecutor (Worker)            BrowserScriptExecutor (wasm bridge)
  subprocess + sandbox                     Pyodide via JavaScriptKit

Core / APIServer / Worker  ── depend up on ──►  RunnerCore
browser-runner.js  →  ~50-line bootstrap (DOM + loaders + POST, zero logic)
```

`RunnerCore` is a **leaf** (depends on nothing, wasm-safe). Everything else
depends *up* on it. Because the wasm build compiles only `RunnerCore` + the
bridge, it never drags `Core`'s heavy deps (swift-crypto) into the browser.

## The protocol

The seam is deliberately **narrow** — the more the substrate must implement, the
less is shared. "A runner" is not a protocol; it's the composition
`executeSuites + some ScriptExecutor`.

```swift
public struct ScriptOutput: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool
}

public enum ScriptKind: Sendable { case python, shell, r, unknown }

public protocol ScriptExecutor {
    func writeFile(_ path: String, _ bytes: [UInt8]) async throws
    func readFile(_ path: String) async -> [UInt8]?
    func run(scriptPath: String, kind: ScriptKind, timeLimitSeconds: Int) async -> ScriptOutput
}

// Shared orchestration — the loop that has drifted lives here, once.
public func executeSuites(
    suites: [SuiteItem],
    workspaceFiles: [WorkspaceFile],
    executor: some ScriptExecutor
) async -> [TestOutcome]
```

**The worker is the first conformance.** When `executeSuites` + `ScriptExecutor`
land, we immediately refactor the worker's existing subprocess loop into
`NativeScriptExecutor` and route it through `executeSuites`. The protocol is
born *exercised* by a real caller — never a floating, speculative interface. The
browser's `BrowserScriptExecutor` (Pyodide via JavaScriptKit) is then a drop-in
second conformance.

## Data-type ownership (resolves the "mirror types vs make-Core-wasm-safe" question)

Neither. **Hoist the canonical runtime model *down* into `RunnerCore`** and have
everyone depend up. No mirror types, no mapping layer, no swift-crypto in the
wasm build, and a single source of truth.

The split line already exists as `TestProperties.runnerSanitized()`:

- **Runtime model → `RunnerCore`:** the sanitized manifest the runner sees,
  suite entries, `TestOutcome` / `TestStatus` / `TestTier`, `ScriptOutput`.
- **Authoring model → stays in `Core`, built on top:** `PatternFamily`,
  `NotebookCheck`, sections, the full `TestProperties` with its authoring fields.

Hoisting is incremental and one-directional (always *into* `RunnerCore`); the
compiler chases every `import`, and we never create a type we later discard.

## Staging

- **Stage 0 — done (#754–#759).** `RunnerCore` exists; the worker delegates
  notebook extraction to it (byte-identical). Dispatch + output/skip contract
  tests. The wasm bridge sub-package (`wasm/`, JavaScriptKit 0.53 + BridgeJS)
  exposes `extractPythonJSON` and is verified end-to-end in Node.

- **Stage 1 — finish the extraction bridge + fix HLTH-230.** esbuild-bundle the
  WASI shim for no-CDN browser load; wire `browser-runner.js` to call
  `extractPythonJSON`; vendor the artifact under `Public/runner-wasm/`. Then emit
  the introspectable-source sidecar on both runners, add a `student_source()`
  runtime helper, and point the structural-check template at it — fixing the
  lab on both runners. No type hoist needed yet.

- **Stage 2 — hoist the leaf logic.** Move `classifyScript` and
  `interpretScriptOutput` (and the types they touch — `ScriptOutput`,
  `TestStatus`) into `RunnerCore`. The cross-runner contract tests become plain
  unit tests (one implementation can't disagree with itself).

- **Stage 3 — the protocol + the loop.** Define `ScriptExecutor` and
  `executeSuites` in `RunnerCore`, hoisting the suite/outcome/manifest types
  with them. **Migrate the worker onto it first** (`NativeScriptExecutor`). Add
  `BrowserScriptExecutor` (Pyodide via JavaScriptKit). Delete the duplicated
  loop in `browser-runner.js`.
  - **Worker half — done.** `ScriptExecutor` (narrow async protocol:
    `scriptExists` + `run`), `SuiteItem` (runtime projection of a manifest
    entry), `SuiteRunEvent`, and the shared async `executeSuites` loop now
    live in `RunnerCore`. The worker drives it via `NativeScriptExecutor`
    (subprocess + sandbox) and maps `SuiteRunEvent`s onto its structured log
    stream; the old in-worker loop and `interpretOutput` are gone.
    `skippedPrerequisiteMessage` moved down into `RunnerCore` too. Verified:
    native build, embedded compile of `RunnerCore`, 222 WorkerTests,
    113 CoreTests (incl. the relocated skip-message pin), 60 JS tests, and
    new `SuiteExecutionTests` unit coverage of the loop.
  - **Embedded async — confirmed working.** Embedded Swift *does* support
    `async` (generic `some ScriptExecutor` witness calls, `@Sendable` closures,
    `await` in `for`/`guard`) — the SDK supplies the cooperative executor. The
    one non-obvious requirement: **`import _Concurrency` must appear in any
    file containing `async` code**, or SILGen crashes (signal 11) instead of
    emitting a diagnostic. `SuiteExecution.swift` / `ScriptExecutor.swift`
    import it with a comment.
  - **Browser half — done (Stage 4).** See below.

- **Stage 4 — thin the shell. DONE (#772).** `browser-runner.js` no longer
  contains a suite loop or output interpretation: it calls `runnerExecuteSuites`
  in the wasm bridge (`JavaScriptEventLoop` + `JSPromise.async` +
  `BrowserScriptExecutor`), which drives the SAME `executeSuites` +
  `interpretScriptOutput` the worker runs. JS supplies only the substrate — a
  `run` callback that executes a script in Pyodide and returns raw
  `ScriptOutput`. The dead JS interpretation cluster (8 functions) was deleted;
  browser- and worker-graded submissions now produce byte-identical
  `TestOutcome`s. Enabling fix: the `JSONLite` number parser was made
  Embedded-safe (no `strtod`, #771). `output-contract.test.mjs` now drives the
  REAL vendored wasm against the shared fixture (cross-runner contract);
  in-browser smoke verified via Preview.

- **Stage 5 — Swift→Wasm review. DONE.** Ran the
  [Swift → Wasm PR Review Checklist](swift-wasm-review-checklist.md) over the
  migration. Report: [runner-wasm-review.md](runner-wasm-review.md). No blocking
  findings; concerns (dynamic JS interop [forced by Embedded], no `wasm-opt`, no
  per-PR wasm-SDK CI build [artifact vendored], no WasmKit test run) are
  documented trade-offs/follow-ups. The `JSFunction`-deprecation warning was
  fixed (unified `JSObject`) so the release build is warning-clean.

## What stays JS forever

The bootstrap above, and Pyodide itself. Everything with a worker counterpart is
shared Swift, compiled once.

## Toolchain & build

- Host Swift toolchain **must match** the wasm SDK version. Currently Swift
  **6.3.2** (via swiftly) + the `swift-6.3.2-RELEASE_wasm` SDK.
- Build the bridge: `scripts/build-runner-wasm.sh` (drives the PackageToJS `js`
  plugin from `wasm/`). Output is vendored under `Public/runner-wasm/`, like
  Pyodide / CodeMirror — so CI and contributors need no wasm SDK; rebuild only
  when `RunnerCore` or the bridge changes.
- `wasm/.build` is excluded from SwiftLint (it would otherwise lint vendored
  JavaScriptKit checkouts).

## Open decisions

- **Stage 1 timing.** Whether to push the browser-wiring + HLTH-230 fix through
  immediately (it un-breaks the lab but is the step most needing in-browser
  verification). The lab stays broken until it lands.
