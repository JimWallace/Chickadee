// Worker/Strategies/PythonBuildStrategy.swift
//
// Phase 2 stub — full implementation in Phase 3.
// Provides a compilable BuildStrategy conformance so the worker daemon
// can reference it; throws NotImplemented if actually invoked.

import Foundation
import Core

struct PythonBuildStrategy: BuildStrategy {
    let language: BuildLanguage = .python
    let runnersDir: URL

    init(runnersDir: URL) {
        self.runnersDir = runnersDir
    }

    func preflight() async throws {
        // Verify python3 is available on PATH.
        let result = try await runCommand("/usr/bin/env", args: ["python3", "--version"])
        guard result == 0 else {
            throw BuildStrategyError.toolNotFound("python3")
        }
    }

    func run(
        submission: URL,
        testSetup: URL,
        manifest: TestSetupManifest
    ) async throws -> RunnerResult {
        let scriptURL = runnersDir
            .appendingPathComponent("python")
            .appendingPathComponent("run_tests.py")

        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw BuildStrategyError.runnerScriptNotFound(scriptURL)
        }

        let encoder    = JSONEncoder()
        let manifestJSON = try String(data: encoder.encode(manifest), encoding: .utf8)!

        let proc       = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments     = [
            "python3", scriptURL.path,
            submission.path,
            testSetup.path,
            manifestJSON
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError  = stderrPipe

        try proc.run()
        proc.waitUntilExit()

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !stderrData.isEmpty {
            fputs(String(data: stderrData, encoding: .utf8) ?? "", stderr)
        }

        guard proc.terminationStatus == 0 else {
            let errText = String(data: stderrData, encoding: .utf8) ?? ""
            throw BuildStrategyError.runnerFailed(
                exitCode: proc.terminationStatus,
                stderr:   errText
            )
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(RunnerResult.self, from: stdoutData)
        } catch {
            let raw = String(data: stdoutData, encoding: .utf8) ?? "<binary>"
            throw BuildStrategyError.invalidRunnerOutput(raw)
        }
    }

    // MARK: - Utility

    @discardableResult
    private func runCommand(_ exe: String, args: [String]) async throws -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments     = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }
}
