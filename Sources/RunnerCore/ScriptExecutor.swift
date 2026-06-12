// RunnerCore/ScriptExecutor.swift
//
// The one irreducible seam between the two runners: *running a script*.
// The native worker runs a subprocess under a sandbox; the browser runner
// drives Pyodide. Everything else — the suite-execution loop, the dependency
// gate, the skip messages, the outcome shaping — is shared (see
// `executeSuites`). Keeping this protocol deliberately narrow is what keeps the
// drift surface small: the more the substrate implements, the less is shared.
//
// This file is part of RunnerCore, which compiles to Embedded Swift for the
// browser wasm build, so it must stay Foundation-free. Scripts are referenced
// by bare name (a `String`), never a Foundation `URL`; the conforming executor
// resolves names against whatever workspace it owns.
//
// `import _Concurrency` is required for the `async` protocol requirements to
// lower under Embedded Swift (see the note in SuiteExecution.swift, and
// upstream https://github.com/swiftlang/swift/issues/89492).
import _Concurrency

/// Runs a single test script and reports whether a named script exists in the
/// workspace. Implementations enforce the time limit themselves.
///
/// Conformances:
/// - `NativeScriptExecutor` (worker) — subprocess + sandbox via `ScriptRunner`.
/// - `BrowserScriptExecutor` (browser, Stage 4) — Pyodide via JavaScriptKit.
public protocol ScriptExecutor {
    /// True if a runnable script with this name exists in the workspace.
    /// A missing script is skipped by `executeSuites` with no emitted outcome,
    /// matching the long-standing worker behaviour.
    func scriptExists(_ name: String) async -> Bool

    /// Run the named script, enforcing `timeLimitSeconds`. Returns the raw
    /// captured output; interpretation into a `TestOutcome` happens in the
    /// shared loop via `interpretScriptOutput`.
    func run(script: String, timeLimitSeconds: Int) async -> ScriptOutput
}

/// Observability hooks emitted by `executeSuites` as it walks the suite list.
/// The loop itself does no logging — the caller supplies an `onEvent` sink and
/// decides what to record. The native worker maps these to its structured
/// `writeStructuredRunnerLog` events; the browser runner can ignore them.
public enum SuiteRunEvent: Sendable {
    /// A referenced script file was not found; no outcome is emitted for it.
    case missingScript(script: String)
    /// About to execute `script` (it exists and its prerequisites passed).
    case willRun(script: String)
    /// Finished executing `script`; carries the resulting outcome and whether
    /// the run timed out (so the caller can distinguish a timeout log event).
    case didFinish(script: String, outcome: TestOutcome, timedOut: Bool)
}
