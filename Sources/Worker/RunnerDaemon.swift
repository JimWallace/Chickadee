// Worker/RunnerDaemon.swift

import Foundation
import ArgumentParser
import Core

// MARK: - Entry point

@main
struct WorkerCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "chickadee-runner",
        abstract: "Chickadee build worker — polls the API server and processes submissions"
    )

    @Option(name: .long, help: "Base URL of the API server (e.g. http://localhost:8080)")
    var apiBaseURL: String = "http://localhost:8080"

    @Option(name: .long, help: "Unique identifier for this worker instance")
    var workerID: String = "worker-\(ProcessInfo.processInfo.hostName)"

    @Option(name: .long, help: "Maximum number of concurrent jobs")
    var maxJobs: Int = 4

    @Flag(name: .long, help: "Run test scripts inside a sandbox (network-isolated, privilege-dropped)")
    var sandbox: Bool = false

    mutating func run() async throws {
        guard let baseURL = URL(string: apiBaseURL) else {
            fputs("Error: invalid --api-base-url '\(apiBaseURL)'\n", stderr)
            throw ExitCode.failure
        }

        let poller   = JobPoller(apiBaseURL: baseURL, workerID: workerID)
        let reporter = Reporter(apiBaseURL: baseURL)
        let runner: any ScriptRunner = sandbox ? SandboxedScriptRunner() : UnsandboxedScriptRunner()

        let daemon = WorkerDaemon(
            poller:            poller,
            reporter:          reporter,
            runner:            runner,
            workerID:          workerID,
            maxConcurrentJobs: maxJobs
        )

        let sandboxLabel = sandbox ? "sandboxed" : "unsandboxed"
        fputs("Worker \(workerID) starting — polling \(apiBaseURL) (max \(maxJobs) concurrent jobs, \(sandboxLabel))\n", stderr)
        try await daemon.run()
    }
}

// MARK: - WorkerDaemon actor

actor WorkerDaemon {
    private let poller:   JobPoller
    private let reporter: Reporter
    private let runner:   any ScriptRunner
    private let workerID: String
    private let maxConcurrentJobs: Int

    init(
        poller:   JobPoller,
        reporter: Reporter,
        runner:   any ScriptRunner,
        workerID: String,
        maxConcurrentJobs: Int
    ) {
        self.poller            = poller
        self.reporter          = reporter
        self.runner            = runner
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

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee_\(job.submissionID)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // Download and unzip both zips.
        let submissionZip = workDir.appendingPathComponent("submission.zip")
        let testSetupZip  = workDir.appendingPathComponent("testsetup.zip")
        let testSetupDir  = workDir.appendingPathComponent("testsetup", isDirectory: true)
        try FileManager.default.createDirectory(at: testSetupDir, withIntermediateDirectories: true)

        try await download(url: job.submissionURL, to: submissionZip)
        try await download(url: job.testSetupURL,  to: testSetupZip)
        try unzip(testSetupZip, to: testSetupDir)

        let manifest = job.manifest

        // Copy required submission files into the test setup dir so scripts can reference them.
        try unzip(submissionZip, to: testSetupDir)

        // Optional make step.
        if let makefile = manifest.makefile {
            try runMake(in: testSetupDir, target: makefile.target)
        }

        // Run each test script and collect outcomes.
        var outcomes: [TestOutcome] = []
        for entry in manifest.testSuites {
            let scriptURL = testSetupDir.appendingPathComponent(entry.script)
            guard FileManager.default.fileExists(atPath: scriptURL.path) else {
                fputs("[\(workerID)] Warning: script not found: \(entry.script)\n", stderr)
                continue
            }

            let output = await runner.run(
                script:           scriptURL,
                workDir:          testSetupDir,
                timeLimitSeconds: manifest.timeLimitSeconds
            )

            let isFirstAttempt = job.attemptNumber == 1
            let outcome = interpretOutput(output, entry: entry, attemptNumber: job.attemptNumber, isFirstAttempt: isFirstAttempt)
            outcomes.append(outcome)
        }

        let collection = makeCollection(outcomes: outcomes, job: job)
        try await reporter.report(collection)

        fputs("[\(workerID)] Reported result for \(job.submissionID) — \(collection.buildStatus.rawValue)\n", stderr)
    }

    // MARK: - Script output interpretation

    private func interpretOutput(
        _ output: ScriptOutput,
        entry: TestSuiteEntry,
        attemptNumber: Int,
        isFirstAttempt: Bool
    ) -> TestOutcome {
        let status: TestOutcomeStatus
        if output.timedOut {
            status = .timeout
        } else {
            switch output.exitCode {
            case 0:  status = .pass
            case 1:  status = .fail
            default: status = .error
            }
        }

        // Parse the last non-empty stdout line as optional JSON for score/shortResult.
        let lastLine = output.stdout
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty })

        var shortResult: String

        if let line = lastLine,
           let data = line.data(using: .utf8),
           let json = try? JSONDecoder().decode(ScriptResultJSON.self, from: data) {
            shortResult = json.shortResult ?? status.defaultShortResult
            // json.score reserved for Phase 5 gamification
        } else if let line = lastLine {
            shortResult = line
        } else {
            shortResult = status.defaultShortResult
        }

        let longResult = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        return TestOutcome(
            testName:           String(entry.script.dropLast(entry.script.hasSuffix(".sh") ? 3 : 0)),
            testClass:          nil,
            tier:               entry.tier,
            status:             status,
            shortResult:        shortResult,
            longResult:         longResult.isEmpty ? nil : longResult,
            executionTimeMs:    output.executionTimeMs,
            memoryUsageBytes:   nil,
            attemptNumber:      attemptNumber,
            isFirstPassSuccess: isFirstAttempt && status == .pass
        )
    }

    // MARK: - Collection assembly

    private func makeCollection(outcomes: [TestOutcome], job: Job) -> TestOutcomeCollection {
        let passCount    = outcomes.filter { $0.status == .pass    }.count
        let failCount    = outcomes.filter { $0.status == .fail    }.count
        let errorCount   = outcomes.filter { $0.status == .error   }.count
        let timeoutCount = outcomes.filter { $0.status == .timeout }.count
        let totalMs      = outcomes.reduce(0) { $0 + $1.executionTimeMs }

        let buildStatus: BuildStatus = outcomes.isEmpty ? .failed : .passed

        return TestOutcomeCollection(
            submissionID:    job.submissionID,
            testSetupID:     job.testSetupID,
            attemptNumber:   job.attemptNumber,
            buildStatus:     buildStatus,
            compilerOutput:  nil,
            outcomes:        outcomes,
            totalTests:      outcomes.count,
            passCount:       passCount,
            failCount:       failCount,
            errorCount:      errorCount,
            timeoutCount:    timeoutCount,
            executionTimeMs: totalMs,
            runnerVersion:   "shell-runner/1.0",
            timestamp:       Date()
        )
    }

    // MARK: - Subprocess helpers

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
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments     = ["-q", "-o", zipFile.path, "-d", directory.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw WorkerDaemonError.unzipFailed(zipFile)
        }
    }

    private func runMake(in directory: URL, target: String?) throws {
        let proc = Process()
        proc.executableURL   = URL(fileURLWithPath: "/usr/bin/make")
        proc.arguments       = target.map { [$0] } ?? []
        proc.currentDirectoryURL = directory
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw WorkerDaemonError.makeFailed(target)
        }
    }
}

// MARK: - Script result JSON (optional last-line protocol)

/// Scripts may optionally write this as their last stdout line to report a score.
private struct ScriptResultJSON: Decodable {
    let score: Double?
    let shortResult: String?
}

// MARK: - Helpers

private extension TestOutcomeStatus {
    var defaultShortResult: String {
        switch self {
        case .pass:    return "passed"
        case .fail:    return "failed"
        case .error:   return "error"
        case .timeout: return "timed out"
        }
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
        let doubled = min(current.components.seconds * 2, max.components.seconds)
        current = Duration.seconds(doubled)
        let jittered = Double.random(in: 0...Double(doubled))
        return Duration.seconds(jittered)
    }

    mutating func reset() {
        current = initial
    }
}

// MARK: - Errors

enum WorkerDaemonError: Error, LocalizedError {
    case downloadFailed(URL)
    case unzipFailed(URL)
    case makeFailed(String?)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let url):  return "Failed to download \(url)"
        case .unzipFailed(let url):     return "Failed to unzip \(url.lastPathComponent)"
        case .makeFailed(let target):   return "make \(target ?? "") failed"
        }
    }
}
