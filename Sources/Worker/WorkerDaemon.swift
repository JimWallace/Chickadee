// Worker/WorkerDaemon.swift
//
// Entry point + actor-based pull loop.
// Spec §2: structured concurrency, AsyncStream, no DispatchQueue/Thread.
// Spec §3: exhaustive BuildError handling.
// Spec §4: BuildServerConfig loaded from JSON; CLI flags available as overrides.
// Spec §6: POSIX file lock for single-instance enforcement.
// Spec §7: WorkerDaemon depends only on BuildServerBackend protocol.
// Spec §8: swift-log Logger, no print()/fputs().

import Foundation
import ArgumentParser
import Logging
import Core

// MARK: - Entry point

@main
struct WorkerCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "Worker",
        abstract: "Chickadee build worker — polls the API server and processes submissions"
    )

    @Option(name: .long, help: "Path to JSON config file (see BuildServerConfig)")
    var config: String?

    // Individual flags override config-file values when both are supplied.
    @Option(name: .long, help: "Base URL of the API server")
    var apiBaseURL: String?

    @Option(name: .long, help: "Unique identifier for this worker instance")
    var workerID: String?

    @Option(name: .long, help: "Maximum number of concurrent jobs")
    var maxJobs: Int?

    @Option(name: .long, help: "Path to the Runners/ directory")
    var runnersDir: String?

    @Option(name: .long, help: "Path to lock file for single-instance enforcement")
    var lockFile: String?

    @Option(name: .long, help: "Log level: trace|debug|info|notice|warning|error|critical")
    var logLevel: String?

    mutating func run() async throws {
        // Load base config from file if provided, otherwise build from flags.
        var cfg: BuildServerConfig
        if let configPath = config {
            cfg = try BuildServerConfig.load(from: URL(fileURLWithPath: configPath))
        } else {
            guard let rawURL = apiBaseURL, let url = URL(string: rawURL) else {
                throw ValidationError("--api-base-url is required when --config is not provided")
            }
            let defaultLockPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("chickadee-worker.lock")
            cfg = BuildServerConfig(
                apiBaseURL:        url,
                workerID:          workerID ?? "worker-\(ProcessInfo.processInfo.hostName)",
                maxConcurrentJobs: maxJobs ?? 4,
                runnersDirectory:  URL(fileURLWithPath: runnersDir ?? "Runners"),
                lockFilePath:      URL(fileURLWithPath: lockFile ?? defaultLockPath.path)
            )
        }

        // Apply individual flag overrides.
        if let rawURL = apiBaseURL, let url = URL(string: rawURL) {
            cfg = BuildServerConfig(apiBaseURL: url, workerID: cfg.workerID,
                maxConcurrentJobs: cfg.maxConcurrentJobs, runnersDirectory: cfg.runnersDirectory,
                lockFilePath: cfg.lockFilePath, logLevel: cfg.logLevel,
                debugDoNotLoop: cfg.debugDoNotLoop)
        }

        // Bootstrap swift-log.
        var logger = Logger(label: "edu.umd.cs.buildServer.worker")
        logger.logLevel = Logger.Level(rawValue: logLevel ?? cfg.logLevel) ?? .info

        // Acquire single-instance lock before doing any real work.
        let lockHandle: FileHandle
        do {
            lockHandle = try acquireLock(at: cfg.lockFilePath)
        } catch BuildError.alreadyRunning {
            logger.critical("Another worker is already running — exiting",
                metadata: ["lockFile": .string(cfg.lockFilePath.path)])
            throw ExitCode.failure
        }
        defer { releaseLock(lockHandle) }

        logger.info("Worker starting",
            metadata: [
                "workerID":  .string(cfg.workerID),
                "apiBase":   .string(cfg.apiBaseURL.absoluteString),
                "maxJobs":   .string("\(cfg.maxConcurrentJobs)"),
                "pid":       .string("\(getpid())"),
            ])

        let backend = DaemonBackend(
            apiBaseURL:         cfg.apiBaseURL,
            workerID:           cfg.workerID,
            supportedLanguages: ["python", "jupyter"],
            logger:             logger
        )

        let daemon = WorkerDaemon(
            backend:           backend,
            runnersDir:        cfg.runnersDirectory,
            workerID:          cfg.workerID,
            maxConcurrentJobs: cfg.maxConcurrentJobs,
            logger:            logger
        )

        try await daemon.run()
    }
}

// MARK: - WorkerDaemon actor

/// Core processing actor.  Depends only on `BuildServerBackend` — never on
/// `DaemonBackend` directly, enabling TestHarnessBackend substitution in tests.
actor WorkerDaemon {
    private let backend: any BuildServerBackend
    private let runnersDir: URL
    private let workerID: String
    private let maxConcurrentJobs: Int
    private var logger: Logger

    init(
        backend: any BuildServerBackend,
        runnersDir: URL,
        workerID: String,
        maxConcurrentJobs: Int,
        logger: Logger
    ) {
        self.backend           = backend
        self.runnersDir        = runnersDir
        self.workerID          = workerID
        self.maxConcurrentJobs = maxConcurrentJobs
        self.logger            = logger
    }

    func run() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<maxConcurrentJobs {
                group.addTask { try await self.workerLoop() }
            }
            try await group.waitForAll()
        }
    }

    // MARK: - Per-slot loop (spec §2 AsyncStream pattern)

    private func workerLoop() async throws {
        for await job in submissionStream() {
            do {
                try await process(job)
            } catch BuildError.compileFailure(let output) {
                logger.warning("Compile failure",
                    metadata: ["submissionID": .string(job.submissionID), "output": .string(output)])
            } catch BuildError.internalError(let msg, _) {
                logger.error("Internal error processing job",
                    metadata: ["submissionID": .string(job.submissionID), "error": .string(msg)])
                await backend.reportDeath(submissionID: job.submissionID, testSetupID: job.testSetupID)
            } catch BuildError.networkFailure(let underlying) {
                logger.error("Network failure, will retry",
                    metadata: ["submissionID": .string(job.submissionID), "error": .string("\(underlying)")])
            } catch {
                logger.error("Unexpected error processing job",
                    metadata: ["submissionID": .string(job.submissionID), "error": .string("\(error)")])
                await backend.reportDeath(submissionID: job.submissionID, testSetupID: job.testSetupID)
            }
        }
    }

    /// Infinite stream of jobs from the API server with exponential backoff + jitter.
    /// Spec §2: AsyncStream pattern.
    private func submissionStream() -> AsyncStream<Job> {
        AsyncStream { continuation in
            Task {
                var noWorkCount = 0
                while true {
                    do {
                        if let job = try await backend.fetchSubmission() {
                            noWorkCount = 0
                            continuation.yield(job)
                        } else {
                            let delay = backoffDuration(noWorkCount: noWorkCount)
                            noWorkCount += 1
                            try await Task.sleep(for: delay)
                        }
                    } catch BuildError.shutdownRequested {
                        continuation.finish()
                        return
                    } catch {
                        // Network hiccup — back off and retry.
                        let delay = backoffDuration(noWorkCount: noWorkCount)
                        noWorkCount = min(noWorkCount + 1, 4)
                        try? await Task.sleep(for: delay)
                    }
                }
            }
        }
    }

    /// Exponential backoff with jitter.
    /// Spec §2: cap = min(noWorkCount, 4), base = 1 << cap seconds, jitter up to base.
    private func backoffDuration(noWorkCount: Int) -> Duration {
        let cap    = min(noWorkCount, 4)
        let base   = Duration.seconds(1 << cap)
        let jitter = Duration.milliseconds(Int.random(in: 0...(1000 * (1 << cap))))
        return base + jitter
    }

    // MARK: - Job processing

    private func process(_ job: Job) async throws {
        logger.info("Processing submission",
            metadata: ["submissionID": .string(job.submissionID),
                       "language":     .string(job.manifest.language.rawValue)])

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee_\(job.submissionID)_\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let submissionZip = workDir.appendingPathComponent("submission.zip")
        let testSetupZip  = workDir.appendingPathComponent("testsetup.zip")
        let testSetupDir  = workDir.appendingPathComponent("testsetup", isDirectory: true)
        try FileManager.default.createDirectory(at: testSetupDir, withIntermediateDirectories: true)

        try await backend.downloadSubmission(job, to: submissionZip)
        try await backend.downloadTestSetup(job,  to: testSetupZip)
        try unzip(testSetupZip, to: testSetupDir)

        let strategy = try strategyFor(job.manifest.language)
        try await strategy.preflight()

        let result = try await strategy.run(
            submission: submissionZip,
            testSetup:  testSetupDir,
            manifest:   job.manifest
        )

        let collection = makeCollection(from: result, job: job)
        try await backend.reportResults(collection, for: job)

        logger.info("Result reported",
            metadata: ["submissionID": .string(job.submissionID),
                       "buildStatus":  .string(collection.buildStatus.rawValue),
                       "pass":         .string("\(collection.passCount)/\(collection.totalTests)")])
    }

    // MARK: - Strategy selection

    private func strategyFor(_ language: BuildLanguage) throws -> BuildStrategy {
        switch language {
        case .python, .jupyter:
            return PythonBuildStrategy(runnersDir: runnersDir, logger: logger)
        }
    }

    // MARK: - Helpers

    private func unzip(_ zipFile: URL, to directory: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments     = ["-q", zipFile.path, "-d", directory.path]
        do {
            try proc.run()
        } catch {
            throw BuildError.internalError("Cannot launch unzip", underlying: error)
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw BuildError.internalError("unzip exited with code \(proc.terminationStatus)")
        }
    }

    private func makeCollection(from result: RunnerResult, job: Job) -> TestOutcomeCollection {
        let outcomes = result.outcomes.map { o in
            TestOutcome(
                testName:         o.testName,
                testClass:        o.testClass,
                tier:             o.tier,
                status:           o.status,
                shortResult:      o.shortResult,
                longResult:       o.longResult,
                executionTimeMs:  o.executionTimeMs,
                memoryUsageBytes: o.memoryUsageBytes,
                score:            nil,
                attemptNumber:    1,
                isFirstPassSuccess: o.status == .pass
            )
        }
        return TestOutcomeCollection(
            submissionID:    job.submissionID,
            testSetupID:     job.testSetupID,
            attemptNumber:   1,
            buildStatus:     result.buildStatus,
            compilerOutput:  result.compilerOutput,
            outcomes:        outcomes,
            totalTests:      outcomes.count,
            passCount:       outcomes.filter { $0.status == .pass    }.count,
            failCount:       outcomes.filter { $0.status == .fail    }.count,
            errorCount:      outcomes.filter { $0.status == .error   }.count,
            timeoutCount:    outcomes.filter { $0.status == .timeout }.count,
            executionTimeMs: result.executionTimeMs,
            runnerVersion:   result.runnerVersion,
            timestamp:       Date()
        )
    }
}
