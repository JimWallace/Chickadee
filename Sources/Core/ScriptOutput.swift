// Core/ScriptOutput.swift
//
// Result of running a single test script subprocess.  Returned by
// implementations of `ScriptRunner` in the worker; converted to
// `TestOutcome` by `RunnerDaemon`.  Lives in `Core` (v0.4.180+) so
// future tooling (server-side validation, tests, etc.) can reference
// the same shape without duplicating it.

import Foundation

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
