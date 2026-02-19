// Worker/ScriptRunner.swift
//
// Protocol and Phase 1 (unsandboxed) implementation for running a single
// test script subprocess. Phase 4 will add SandboxedScriptRunner conforming
// to the same protocol without changing any callers.

import Foundation

/// Runs a single test script and returns raw output.
/// Implementations are responsible for enforcing the time limit.
protocol ScriptRunner {
    func run(script: URL, workDir: URL, timeLimitSeconds: Int) async -> ScriptOutput
}

/// Phase 1: direct subprocess execution, no sandbox.
struct UnsandboxedScriptRunner: ScriptRunner {

    func run(script: URL, workDir: URL, timeLimitSeconds: Int) async -> ScriptOutput {
        let start = Date()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments     = [script.path]
        proc.currentDirectoryURL = workDir

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError  = stderrPipe

        do {
            try proc.run()
        } catch {
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            return ScriptOutput(
                exitCode: 2,
                stdout: "",
                stderr: "Failed to launch script: \(error.localizedDescription)",
                executionTimeMs: elapsed,
                timedOut: false
            )
        }

        // Enforce time limit: kill the process after timeLimitSeconds.
        var timedOut = false
        let timeoutItem = DispatchWorkItem {
            if proc.isRunning {
                timedOut = true
                proc.terminate()         // SIGTERM first
                Thread.sleep(forTimeInterval: 0.5)
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
            }
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .seconds(timeLimitSeconds),
            execute: timeoutItem
        )

        proc.waitUntilExit()
        timeoutItem.cancel()

        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return ScriptOutput(
            exitCode: timedOut ? -1 : proc.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            executionTimeMs: elapsed,
            timedOut: timedOut
        )
    }
}
