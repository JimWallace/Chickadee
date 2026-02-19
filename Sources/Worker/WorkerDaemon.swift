// Worker/WorkerDaemon.swift
//
// Phase 1 stub: processes a single submission directly from the command line
// without HTTP polling or sandboxing. Full actor-based daemon comes in Phase 2.

import Foundation
import ArgumentParser
import Core

@main
struct WorkerCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "Worker",
        abstract: "Chickadee build worker — Phase 1 CLI stub"
    )

    @Option(name: .long, help: "Path to the submission zip file")
    var submission: String

    @Option(name: .long, help: "Path to the test setup directory")
    var testsetup: String

    @Option(name: .long, help: "Path to the Runners/ directory")
    var runnersDir: String = "Runners"

    @Option(name: .long, help: "Submission ID (used in output)")
    var submissionID: String = "sub_local"

    @Option(name: .long, help: "Test setup ID (used in output)")
    var testSetupID: String = "setup_local"

    mutating func run() async throws {
        let submissionURL = URL(fileURLWithPath: submission)
        let testSetupURL  = URL(fileURLWithPath: testsetup)
        let runnersDirURL = URL(fileURLWithPath: runnersDir)

        // Read and parse manifest from test setup directory
        let manifestURL = testSetupURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            fputs("Error: manifest.json not found in testsetup directory\n", stderr)
            throw ExitCode.failure
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(TestSetupManifest.self, from: manifestData)

        // Select strategy
        let strategy: BuildStrategy
        switch manifest.language {
        case .python, .jupyter:
            fputs("Python/Jupyter support not yet implemented (Phase 2)\n", stderr)
            throw ExitCode.failure
        }

        // Preflight check
        try await strategy.preflight()

        // Run build + tests
        fputs("Running \(manifest.language.rawValue) build strategy...\n", stderr)
        let result = try await strategy.run(
            submission: submissionURL,
            testSetup: testSetupURL,
            manifest: manifest
        )

        // Convert RunnerResult → TestOutcomeCollection
        let collection = makeCollection(from: result, manifest: manifest)

        // Print result as JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let outputData = try encoder.encode(collection)
        print(String(data: outputData, encoding: .utf8) ?? "")
    }

    private func makeCollection(
        from result: RunnerResult,
        manifest: TestSetupManifest
    ) -> TestOutcomeCollection {
        let outcomes = result.outcomes.map { o in
            TestOutcome(
                testName: o.testName,
                testClass: o.testClass,
                tier: o.tier,
                status: o.status,
                shortResult: o.shortResult,
                longResult: o.longResult,
                executionTimeMs: o.executionTimeMs,
                memoryUsageBytes: o.memoryUsageBytes,
                score: nil,
                attemptNumber: 1,
                isFirstPassSuccess: o.status == .pass
            )
        }

        let passCount    = outcomes.filter { $0.status == .pass }.count
        let failCount    = outcomes.filter { $0.status == .fail }.count
        let errorCount   = outcomes.filter { $0.status == .error }.count
        let timeoutCount = outcomes.filter { $0.status == .timeout }.count

        return TestOutcomeCollection(
            submissionID: submissionID,
            testSetupID: testSetupID,
            attemptNumber: 1,
            buildStatus: result.buildStatus,
            compilerOutput: result.compilerOutput,
            outcomes: outcomes,
            totalTests: outcomes.count,
            passCount: passCount,
            failCount: failCount,
            errorCount: errorCount,
            timeoutCount: timeoutCount,
            executionTimeMs: result.executionTimeMs,
            runnerVersion: result.runnerVersion,
            timestamp: Date()
        )
    }
}
