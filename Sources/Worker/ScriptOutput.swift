// Worker/ScriptOutput.swift
//
// Internal result of running a single test script subprocess.
// Converted to TestOutcome by RunnerDaemon.

import Foundation

struct ScriptOutput {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let executionTimeMs: Int
    let timedOut: Bool
}
