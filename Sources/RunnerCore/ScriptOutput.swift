// RunnerCore/ScriptOutput.swift
//
// Result of running a single test script subprocess.  Returned by
// implementations of `ScriptRunner` in the worker; converted to
// `TestOutcome` by `RunnerDaemon`.  Lives in `RunnerCore` (the wasm-safe,
// dependency-free leaf) so both the worker and the browser runner share the
// shape; `Core` re-exports it via `@_exported import RunnerCore`.

public struct ScriptOutput: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let executionTimeMs: Int
    public let timedOut: Bool

    public init(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        executionTimeMs: Int,
        timedOut: Bool
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.executionTimeMs = executionTimeMs
        self.timedOut = timedOut
    }
}
