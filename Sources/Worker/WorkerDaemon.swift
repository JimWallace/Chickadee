// Worker/WorkerDaemon.swift
//
// Phase 2: full actor-based pull loop.
// Replaces the Phase 1 single-shot CLI stub.

import Foundation
import ArgumentParser
import Core

// MARK: - Entry point

@main
struct WorkerCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "Worker",
        abstract: "Chickadee build worker — polls the API server and processes submissions"
    )

    @Option(name: .long, help: "Base URL of the API server (e.g. http://localhost:8080)")
    var apiBaseURL: String = "http://localhost:8080"

    @Option(name: .long, help: "Unique identifier for this worker instance")
    var workerID: String = "worker-\(ProcessInfo.processInfo.hostName)"

    @Option(name: .long, help: "Maximum number of concurrent jobs")
    var maxJobs: Int = 4

    @Option(name: .long, help: "Path to the Runners/ directory")
    var runnersDir: String = "Runners"

    mutating func run() async throws {
        guard let baseURL = URL(string: apiBaseURL) else {
            fputs("Error: invalid --api-base-url '\(apiBaseURL)'\n", stderr)
            throw ExitCode.failure
        }

        let poller   = JobPoller(
            apiBaseURL:         baseURL,
            workerID:           workerID,
            supportedLanguages: ["python", "jupyter"]
        )
        let reporter = Reporter(apiBaseURL: baseURL)
        let runnersDirURL = URL(fileURLWithPath: runnersDir)

        let daemon = WorkerDaemon(
            poller:      poller,
            reporter:    reporter,
            runnersDir:  runnersDirURL,
            workerID:    workerID,
            maxConcurrentJobs: maxJobs
        )

        fputs("Worker \(workerID) starting — polling \(apiBaseURL) (max \(maxJobs) concurrent jobs)\n", stderr)
        try await daemon.run()
    }
}

// MARK: - WorkerDaemon actor

actor WorkerDaemon {
    private let poller:   JobPoller
    private let reporter: Reporter
    private let runnersDir: URL
    private let workerID: String
    private let maxConcurrentJobs: Int

    init(
        poller:   JobPoller,
        reporter: Reporter,
        runnersDir: URL,
        workerID: String,
        maxConcurrentJobs: Int
    ) {
        self.poller            = poller
        self.reporter          = reporter
        self.runnersDir        = runnersDir
        self.workerID          = workerID
        self.maxConcurrentJobs = maxConcurrentJobs
    }

    func run() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<maxConcurrentJobs {
                group.addTask { try await self.workerLoop() }
            }
            try await group.waitForAll()
        }
    }

    // MARK: - Per-worker loop

    private func workerLoop() async throws {
        var backoff = ExponentialBackoff(initial: .seconds(1), max: .seconds(30))
        while true {
            if let job = try await poller.requestJob() {
                backoff.reset()
                do {
                    try await process(job)
                } catch {
                    fputs("[\(workerID)] Error processing job \(job.submissionID): \(error)\n", stderr)
                }
            } else {
                let delay = backoff.next()
                try await Task.sleep(for: delay)
            }
        }
    }

    // MARK: - Job processing

    private func process(_ job: Job) async throws {
        fputs("[\(workerID)] Processing submission \(job.submissionID)\n", stderr)

        // Download submission and test-setup zips to temp dirs.
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee_\(job.submissionID)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workDir)
        }

        let submissionZip = workDir.appendingPathComponent("submission.zip")
        let testSetupDir  = workDir.appendingPathComponent("testsetup", isDirectory: true)
        try FileManager.default.createDirectory(at: testSetupDir, withIntermediateDirectories: true)
        let testSetupZip  = workDir.appendingPathComponent("testsetup.zip")

        try await download(url: job.submissionURL, to: submissionZip)
        try await download(url: job.testSetupURL,  to: testSetupZip)

        // Unzip test setup into testSetupDir.
        try unzip(testSetupZip, to: testSetupDir)

        // Dispatch to the appropriate strategy.
        let strategy = try strategyFor(job.manifest.language)
        try await strategy.preflight()

        let result = try await strategy.run(
            submission: submissionZip,
            testSetup:  testSetupDir,
            manifest:   job.manifest
        )

        let collection = makeCollection(from: result, job: job)
        try await reporter.report(collection)

        fputs("[\(workerID)] Reported result for \(job.submissionID) — \(collection.buildStatus.rawValue)\n", stderr)
    }

    // MARK: - Strategy selection

    private func strategyFor(_ language: BuildLanguage) throws -> BuildStrategy {
        switch language {
        case .python, .jupyter:
            return PythonBuildStrategy(runnersDir: runnersDir)
        }
    }

    // MARK: - Helpers

    private func download(url: URL, to destination: URL) async throws {
        let (tmpURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WorkerDaemonError.downloadFailed(url)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tmpURL, to: destination)
    }

    private func unzip(_ zipFile: URL, to directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments     = ["-q", zipFile.path, "-d", directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw WorkerDaemonError.unzipFailed(zipFile)
        }
    }

    private func makeCollection(from result: RunnerResult, job: Job) -> TestOutcomeCollection {
        let outcomes = result.outcomes.map { o in
            TestOutcome(
                testName:        o.testName,
                testClass:       o.testClass,
                tier:            o.tier,
                status:          o.status,
                shortResult:     o.shortResult,
                longResult:      o.longResult,
                executionTimeMs: o.executionTimeMs,
                memoryUsageBytes: o.memoryUsageBytes,
                score:           nil,
                attemptNumber:   1,
                isFirstPassSuccess: o.status == .pass
            )
        }

        let passCount    = outcomes.filter { $0.status == .pass    }.count
        let failCount    = outcomes.filter { $0.status == .fail    }.count
        let errorCount   = outcomes.filter { $0.status == .error   }.count
        let timeoutCount = outcomes.filter { $0.status == .timeout }.count

        return TestOutcomeCollection(
            submissionID:    job.submissionID,
            testSetupID:     job.testSetupID,
            attemptNumber:   1,
            buildStatus:     result.buildStatus,
            compilerOutput:  result.compilerOutput,
            outcomes:        outcomes,
            totalTests:      outcomes.count,
            passCount:       passCount,
            failCount:       failCount,
            errorCount:      errorCount,
            timeoutCount:    timeoutCount,
            executionTimeMs: result.executionTimeMs,
            runnerVersion:   result.runnerVersion,
            timestamp:       Date()
        )
    }
}

// MARK: - ExponentialBackoff

struct ExponentialBackoff {
    private let initial: Duration
    private let max: Duration
    private var current: Duration

    init(initial: Duration, max: Duration) {
        self.initial = initial
        self.max     = max
        self.current = initial
    }

    mutating func next() -> Duration {
        let value = current
        // Double the delay, capped at max.
        let doubled = Duration.seconds(
            min(current.components.seconds * 2, max.components.seconds)
        )
        current = doubled
        return value
    }

    mutating func reset() {
        current = initial
    }
}

// MARK: - Errors

enum WorkerDaemonError: Error, LocalizedError {
    case downloadFailed(URL)
    case unzipFailed(URL)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let url): return "Failed to download \(url)"
        case .unzipFailed(let url):    return "Failed to unzip \(url.lastPathComponent)"
        }
    }
}
