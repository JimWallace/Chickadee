// Worker/Strategies/PythonBuildStrategy.swift
//
// Phase 2 stub — full runner script implemented in Phase 3.
// Spec §3: throws BuildError throughout.
// Spec §8: uses Logger; no fputs()/print().

import Foundation
import Core
import Logging

struct PythonBuildStrategy: BuildStrategy {
    let language: BuildLanguage = .python
    let runnersDir: URL
    var logger: Logger

    init(runnersDir: URL, logger: Logger) {
        self.runnersDir = runnersDir
        self.logger     = logger
    }

    func preflight() async throws {
        let status = try await runCommand("/usr/bin/env", args: ["python3", "--version"])
        guard status == 0 else {
            throw BuildError.internalError("python3 not found on PATH")
        }
        logger.debug("python3 preflight passed")
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
            throw BuildError.internalError("Runner script not found at \(scriptURL.path)")
        }

        let manifestJSON: String
        do {
            let data = try JSONEncoder().encode(manifest)
            manifestJSON = String(data: data, encoding: .utf8)!
        } catch {
            throw BuildError.internalError("Failed to encode manifest", underlying: error)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments     = ["python3", scriptURL.path,
                               submission.path, testSetup.path, manifestJSON]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError  = stderrPipe

        do {
            try proc.run()
        } catch {
            throw BuildError.internalError("Failed to launch runner", underlying: error)
        }
        proc.waitUntilExit()

        let stderrText = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""
        if !stderrText.isEmpty {
            logger.debug("Runner stderr", metadata: ["output": .string(stderrText)])
        }

        // Non-zero exit is an infrastructure error (not a compile failure).
        // Compile failures are reported inside the JSON with buildStatus "failed".
        guard proc.terminationStatus == 0 else {
            throw BuildError.internalError(
                "Runner exited with code \(proc.terminationStatus): \(stderrText)")
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        do {
            return try JSONDecoder().decode(RunnerResult.self, from: stdoutData)
        } catch {
            let raw = String(data: stdoutData, encoding: .utf8) ?? "<binary>"
            throw BuildError.internalError("Cannot parse runner JSON: \(raw)")
        }
    }

    // MARK: - Utility

    @discardableResult
    private func runCommand(_ exe: String, args: [String]) async throws -> Int32 {
        let proc = Process()
        proc.executableURL  = URL(fileURLWithPath: exe)
        proc.arguments      = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice
        do { try proc.run() } catch {
            throw BuildError.internalError("Cannot launch \(exe)", underlying: error)
        }
        proc.waitUntilExit()
        return proc.terminationStatus
    }
}
