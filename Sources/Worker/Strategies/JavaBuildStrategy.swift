// Worker/Strategies/JavaBuildStrategy.swift

import Foundation
import Core

/// Build strategy that invokes Runners/java/run_tests.sh.
struct JavaBuildStrategy: BuildStrategy {

    let language: BuildLanguage = .java

    /// Path to the Runners/ directory (contains java/run_tests.sh).
    let runnersDir: URL

    init(runnersDir: URL) {
        self.runnersDir = runnersDir
    }

    // MARK: - BuildStrategy

    func preflight() async throws {
        for tool in ["javac", "java", "python3", "unzip"] {
            guard toolExists(tool) else {
                throw BuildStrategyError.toolNotFound(tool)
            }
        }

        let script = runnerScript
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw BuildStrategyError.runnerScriptNotFound(script)
        }
    }

    func run(
        submission: URL,
        testSetup: URL,
        manifest: TestSetupManifest
    ) async throws -> RunnerResult {
        let manifestFile = try writeTempManifest(manifest)
        defer { try? FileManager.default.removeItem(at: manifestFile) }

        let (stdout, stderr, exitCode) = try await launchRunner(
            submission: submission,
            testSetup: testSetup,
            manifestFile: manifestFile
        )

        if exitCode != 0 {
            throw BuildStrategyError.runnerFailed(exitCode: exitCode, stderr: stderr)
        }

        guard let data = stdout.data(using: .utf8) else {
            throw BuildStrategyError.invalidRunnerOutput("stdout is not valid UTF-8")
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(RunnerResult.self, from: data)
        } catch {
            throw BuildStrategyError.invalidRunnerOutput(error.localizedDescription)
        }
    }

    // MARK: - Private

    private var runnerScript: URL {
        runnersDir.appendingPathComponent("java/run_tests.sh")
    }

    private func toolExists(_ name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func writeTempManifest(_ manifest: TestSetupManifest) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(manifest)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-\(UUID().uuidString).json")
        try data.write(to: url)
        return url
    }

    private func launchRunner(
        submission: URL,
        testSetup: URL,
        manifestFile: URL
    ) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            runnerScript.path,
            submission.path,
            testSetup.path,
            manifestFile.path,
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Read output asynchronously to avoid deadlocks on large output
        async let stdoutData = readAll(pipe: stdoutPipe)
        async let stderrData = readAll(pipe: stderrPipe)

        let (outData, errData) = try await (stdoutData, stderrData)

        process.waitUntilExit()

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        return (stdout, stderr, process.terminationStatus)
    }

    private func readAll(pipe: Pipe) async throws -> Data {
        var result = Data()
        for try await chunk in pipe.fileHandleForReading.bytes {
            result.append(chunk)
        }
        return result
    }
}
