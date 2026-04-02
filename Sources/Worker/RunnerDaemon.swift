// Worker/RunnerDaemon.swift

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession, URLRequest on Linux
#endif
import ArgumentParser
import Core

private enum RunnerJobStatus: String {
    case passed
    case failed
    case error
    case timeout
}

private func writeToStandardError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

func writeStructuredRunnerLog(event: String, fields: [String: Any]) {
    var payload = fields
    payload["timestamp"] = ISO8601DateFormatter().string(from: Date())
    payload["event"] = event
    guard JSONSerialization.isValidJSONObject(payload),
          let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
        writeToStandardError("{\"event\":\"\(event)\",\"timestamp\":\"\(ISO8601DateFormatter().string(from: Date()))\"}\n")
        return
    }
    FileHandle.standardError.write(data)
    FileHandle.standardError.write(Data("\n".utf8))
}

// MARK: - Entry point

@main
struct WorkerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chickadee-runner",
        abstract: "Chickadee build runner — polls the API server and processes submissions",
        version: ChickadeeVersion.current
    )

    @Option(name: .long, help: "Base URL of the API server (e.g. http://localhost:8080)")
    var apiBaseURL: String = "http://localhost:8080"

    @Option(name: .long, help: "Unique identifier for this runner instance")
    var workerID: String = "worker-\(ProcessInfo.processInfo.hostName)"

    @Option(name: .long, help: "Maximum number of concurrent jobs")
    var maxJobs: Int = 4

    @Flag(name: .long, help: "Run test scripts inside a sandbox (network-isolated, privilege-dropped)")
    var sandbox: Bool = false

    @Option(name: .long, help: "Runner shared secret for API auth (or RUNNER_SHARED_SECRET env var)")
    var workerSecret: String?

    mutating func run() async throws {
        guard let baseURL = URL(string: apiBaseURL) else {
            writeToStandardError("Error: invalid --api-base-url '\(apiBaseURL)'\n")
            throw ExitCode.failure
        }

        let env = ProcessInfo.processInfo.environment
        let capabilityDiscoveryEnabled = runnerEnvironmentBool("RUNNER_CAPABILITY_DISCOVERY_ENABLED", default: true)
        let runnerProfile = RunnerProfileDetector(discoveryEnabled: capabilityDiscoveryEnabled).detect()
        guard let effectiveWorkerSecret = resolveWorkerSharedSecret(
            cliWorkerSecret: workerSecret,
            environment: env
        ) else {
            writeToStandardError("Error: missing runner secret. Use --worker-secret or set RUNNER_SHARED_SECRET.\n")
            throw ExitCode.failure
        }

        let poller   = JobPoller(
            apiBaseURL: baseURL,
            workerID: workerID,
            workerSecret: effectiveWorkerSecret,
            maxConcurrentJobs: maxJobs,
            profile: runnerProfile
        )
        let reporter = Reporter(apiBaseURL: baseURL, workerID: workerID, workerSecret: effectiveWorkerSecret)
        let runner: any ScriptRunner = sandbox ? SandboxedScriptRunner() : UnsandboxedScriptRunner()

        let daemon = WorkerDaemon(
            poller:            poller,
            reporter:          reporter,
            runner:            runner,
            apiBaseURL:        baseURL,
            workerID:          workerID,
            workerSecret:      effectiveWorkerSecret,
            maxConcurrentJobs: maxJobs,
            runnerProfile:     runnerProfile
        )

        let sandboxLabel = sandbox ? "sandboxed" : "unsandboxed"
        writeStructuredRunnerLog(event: "runner_startup", fields: [
            "runner_id": workerID,
            "status": "starting",
        ])
        writeStructuredRunnerLog(event: "runner_configuration", fields: [
            "runner_id": workerID,
            "api_base_url": apiBaseURL,
            "max_jobs": maxJobs,
            "sandbox_mode": sandboxLabel,
        ])
        if let runnerProfile {
            writeStructuredRunnerLog(event: "runner_profile_detected", fields: [
                "runner_id": workerID,
                "platform": runnerProfile.platform,
                "architecture": runnerProfile.architecture,
                "languages": runnerProfile.languageVersions.map { "\($0.language)=\($0.version)" },
                "capabilities": runnerProfile.capabilities.map(\.name),
            ])
        }
        try await daemon.run()
    }
}

func resolveWorkerSharedSecret(
    cliWorkerSecret: String?,
    environment: [String: String]
) -> String? {
    let cliSecret = cliWorkerSecret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !cliSecret.isEmpty { return cliSecret }

    let envSecret = (environment["RUNNER_SHARED_SECRET"] ?? environment["WORKER_SHARED_SECRET"] ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if !envSecret.isEmpty { return envSecret }

    for path in defaultWorkerSecretFilePaths() {
        if let fileSecret = readWorkerSecretFromFile(path: path) {
            return fileSecret
        }
    }

    return nil
}

func defaultWorkerSecretFilePaths() -> [String] {
    var paths: [String] = []

    let cwd = FileManager.default.currentDirectoryPath
    if !cwd.isEmpty {
        paths.append(URL(fileURLWithPath: cwd).appendingPathComponent(".worker-secret").path)
    }

    let dockerSharedPath = "/data/.worker-secret"
    if !paths.contains(dockerSharedPath) {
        paths.append(dockerSharedPath)
    }

    return paths
}

func readWorkerSecretFromFile(path: String) -> String? {
    guard !path.isEmpty,
          let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
        return nil
    }

    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

// MARK: - WorkerDaemon actor

actor WorkerDaemon {
    private static let downloadSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 15
        return URLSession(configuration: cfg)
    }()

    private let poller:   any JobPolling
    private let reporter: any Reporting
    private let runner:   any ScriptRunner
    private let apiBaseURL: URL
    private let workerID: String
    private let signer: WorkerRequestSigner
    private let maxConcurrentJobs: Int
    private let runnerProfile: RunnerCapabilityProfile?
    private let downloadRetryPolicy: RunnerRetryPolicy
    private var serverConnectionLost = false
    private var activeJobs = 0

    init(
        poller:   any JobPolling,
        reporter: any Reporting,
        runner:   any ScriptRunner,
        apiBaseURL: URL,
        workerID: String,
        workerSecret: String,
        maxConcurrentJobs: Int,
        runnerProfile: RunnerCapabilityProfile? = nil,
        downloadRetryPolicy: RunnerRetryPolicy = .download()
    ) {
        self.poller            = poller
        self.reporter          = reporter
        self.runner            = runner
        self.apiBaseURL        = apiBaseURL
        self.workerID          = workerID
        self.signer            = WorkerRequestSigner(sharedSecret: workerSecret, workerID: workerID)
        self.maxConcurrentJobs = maxConcurrentJobs
        self.runnerProfile     = runnerProfile
        self.downloadRetryPolicy = downloadRetryPolicy
    }

    func run() async throws {
        defer {
            writeStructuredRunnerLog(event: "runner_shutdown", fields: [
                "runner_id": workerID,
                "status": "stopped",
            ])
        }
        try await withThrowingDiscardingTaskGroup { group in
            for slot in 0..<maxConcurrentJobs {
                group.addTask { try await self.workerLoop(slot: slot) }
            }
        }
    }

    // MARK: - Per-worker loop

    private func workerLoop(slot: Int) async throws {
        var backoff = ExponentialBackoff(initial: .seconds(1), max: .seconds(30))
        while !Task.isCancelled {
            do {
                let currentActiveJobs = activeJobs
                writeStructuredRunnerLog(event: "poll_cycle_start", fields: [
                    "runner_id": workerID,
                    "slot": slot,
                    "runner_active_jobs": currentActiveJobs,
                    "max_jobs": maxConcurrentJobs,
                    "api_base_url": apiBaseURL.absoluteString,
                ])
                if let job = try await poller.requestJob(activeJobs: currentActiveJobs) {
                    recordConnectionRestoredIfNeeded(stage: .poll)
                    backoff.reset()
                    writeStructuredRunnerLog(event: "poll_cycle_end", fields: [
                        "runner_id": workerID,
                        "slot": slot,
                        "status": "job_assigned",
                        "submission_id": job.submissionID,
                    ])
                    do {
                        try await process(job)
                    } catch {
                        writeStructuredRunnerLog(event: "local_execution_error", fields: [
                            "runner_id": workerID,
                            "submission_id": job.submissionID,
                            "error_type": String(describing: type(of: error)),
                            "error_message_summary": String(describing: error),
                        ])
                        try? await reportProcessingFailure(job: job, error: error)
                    }
                } else {
                    writeStructuredRunnerLog(event: "poll_cycle_end", fields: [
                        "runner_id": workerID,
                        "slot": slot,
                        "status": "no_job",
                    ])
                    let delay = backoff.next()
                    try await Task.sleep(for: delay)
                }
            } catch JobPollerError.duplicateWorkerID(let message) {
                let delay = backoff.next()
                let seconds = delay.components.seconds
                recordConnectionLostIfNeeded(
                    stage: .poll,
                    message: message,
                    retryInSeconds: Int(seconds)
                )
                writeStructuredRunnerLog(event: "poll_cycle_end", fields: [
                    "runner_id": workerID,
                    "slot": slot,
                    "status": "duplicate_worker_id",
                    "failure_stage": RunnerRetryStage.poll.rawValue,
                    "retryable": true,
                    "error_message_summary": message,
                    "retry_in_seconds": seconds,
                ])
                try await Task.sleep(for: delay)
            } catch JobPollerError.transportError(let underlying) {
                // Server is unreachable (connection refused, DNS failure, etc.).
                // Apply the same exponential backoff used for the no-job poll and
                // keep retrying so the runner survives server restarts automatically.
                let delay = backoff.next()
                let seconds = delay.components.seconds
                recordConnectionLostIfNeeded(
                    stage: .poll,
                    message: underlying.localizedDescription,
                    retryInSeconds: Int(seconds)
                )
                writeStructuredRunnerLog(event: "poll_cycle_end", fields: [
                    "runner_id": workerID,
                    "slot": slot,
                    "status": "transport_error",
                    "failure_stage": RunnerRetryStage.poll.rawValue,
                    "retryable": true,
                    "error_message_summary": underlying.localizedDescription,
                    "retry_in_seconds": seconds,
                ])
                try await Task.sleep(for: delay)
            } catch JobPollerError.httpError(let statusCode, let body) {
                let disposition = classifyHTTPRetry(statusCode: statusCode, body: body)
                switch disposition {
                case .retryable(let message):
                    let delay = backoff.next()
                    let seconds = delay.components.seconds
                    recordConnectionLostIfNeeded(
                        stage: .poll,
                        message: message,
                        retryInSeconds: Int(seconds)
                    )
                    writeStructuredRunnerLog(event: "poll_cycle_end", fields: [
                        "runner_id": workerID,
                        "slot": slot,
                        "status": "http_error",
                        "failure_stage": RunnerRetryStage.poll.rawValue,
                        "retryable": true,
                        "http_status": statusCode,
                        "error_message_summary": message,
                        "retry_in_seconds": seconds,
                    ])
                    try await Task.sleep(for: delay)
                case .terminal(let message):
                    writeStructuredRunnerLog(event: "poll_cycle_end", fields: [
                        "runner_id": workerID,
                        "slot": slot,
                        "status": "http_error",
                        "failure_stage": RunnerRetryStage.poll.rawValue,
                        "retryable": false,
                        "http_status": statusCode,
                        "error_message_summary": message,
                    ])
                    throw JobPollerError.httpError(statusCode, body)
                }
            } catch JobPollerError.unexpectedResponse {
                let delay = backoff.next()
                let seconds = delay.components.seconds
                recordConnectionLostIfNeeded(
                    stage: .poll,
                    message: "unexpected response from API server",
                    retryInSeconds: Int(seconds)
                )
                writeStructuredRunnerLog(event: "poll_cycle_end", fields: [
                    "runner_id": workerID,
                    "slot": slot,
                    "status": "unexpected_response",
                    "failure_stage": RunnerRetryStage.poll.rawValue,
                    "retryable": true,
                    "error_message_summary": "unexpected response from API server",
                    "retry_in_seconds": seconds,
                ])
                try await Task.sleep(for: delay)
            }
        }
    }

    // MARK: - Job processing

    private func process(_ job: Job) async throws {
        activeJobs += 1
        let jobStartedAt = Date()
        defer { activeJobs = max(0, activeJobs - 1) }

        writeStructuredRunnerLog(event: "job_accepted", fields: [
            "runner_id": workerID,
            "submission_id": job.submissionID,
            "job_id": job.submissionID,
            "test_setup_id": job.testSetupID,
            "attempt_number": job.attemptNumber,
            "runner_active_jobs": activeJobs,
            "max_jobs": maxConcurrentJobs,
        ])
        try? await sendHeartbeat()

        let heartbeatTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                try? await self.sendHeartbeat()
            }
        }
        defer {
            heartbeatTask.cancel()
            Task { try? await self.sendHeartbeat() }
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee_\(job.submissionID)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // Download and unzip both zips.
        let submissionZip = workDir.appendingPathComponent("submission.zip")
        let testSetupZip  = workDir.appendingPathComponent("testsetup.zip")
        let testSetupDir  = workDir.appendingPathComponent("testsetup", isDirectory: true)
        let submissionDir = workDir.appendingPathComponent("submission", isDirectory: true)
        try FileManager.default.createDirectory(at: testSetupDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: submissionDir, withIntermediateDirectories: true)

        async let submissionDownload: Void = download(url: job.submissionURL, to: submissionZip)
        async let testSetupDownload: Void  = download(url: job.testSetupURL,  to: testSetupZip)
        try await submissionDownload
        try await testSetupDownload
        try unzip(testSetupZip, to: testSetupDir)

        let manifest = job.manifest

        // Stage the submission independently from the grading workspace so the
        // worker can normalize it without mutating the raw artifact.
        if let filename = job.submissionFilename {
            let dest = submissionDir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: submissionZip, to: dest)
        } else {
            try unzip(submissionZip, to: submissionDir)
        }

        // Remove the starter notebook template from the test directory so
        // grading scripts that scan for *.ipynb don't see both the template
        // and the student/canonical submission.  Older manifests lack
        // starterNotebook — fall back to "assignment.ipynb" since that is
        // the conventional name used by every existing assignment.
        let starterName = manifest.starterNotebook ?? "assignment.ipynb"
        do {
            let starterPath = testSetupDir.appendingPathComponent(starterName)
            if FileManager.default.fileExists(atPath: starterPath.path),
               job.submissionFilename != starterName {
                try FileManager.default.removeItem(at: starterPath)
            }
        }

        let normalizationWarnings: [String]
        let preferredStudentModule: String?
        if shouldNormalizePythonSubmission(
            manifest: manifest,
            submissionFilename: job.submissionFilename,
            submissionDirectory: submissionDir
        ) {
            let normalizer = SubmissionNormalizer()
            let normalization = try normalizer.normalizePythonSubmission(
                manifest: manifest,
                submissionDirectory: submissionDir,
                workspaceDirectory: testSetupDir,
                submissionFilename: job.submissionFilename
            )
            normalizationWarnings = normalization.warnings
            preferredStudentModule = normalization.preferredStudentModule
        } else {
            try mergeDirectoryContents(from: submissionDir, into: testSetupDir)
            try extractNotebooksToCode(in: testSetupDir)
            normalizationWarnings = []
            preferredStudentModule = legacyPreferredStudentModuleFilename(submissionFilename: job.submissionFilename)
        }

        // Optional make step.
        if let makefile = manifest.makefile {
            try runMake(in: testSetupDir, target: makefile.target)
        }

        // Install shared Python test runtime helpers for every run.
        try writePythonRuntimeHelpers(in: testSetupDir)
        try writeStudentModuleHint(in: testSetupDir, preferredFilename: preferredStudentModule)

        // Install shared R test runtime helpers for every run.
        try writeRRuntimeHelper(in: testSetupDir)

        // Run each test script and collect outcomes.
        // `passedScripts` tracks which scripts produced a .pass outcome so that
        // dependent tests can check their prerequisites before running.
        var outcomes: [TestOutcome] = []
        var passedScripts: Set<String> = []

        for entry in manifest.testSuites {
            // Dependency pre-check: if any prerequisite did not pass, auto-fail
            // without running the script.
            if let blockedBy = entry.dependsOn.first(where: { !passedScripts.contains($0) }),
               !entry.dependsOn.isEmpty {
                let baseName = (entry.script as NSString).deletingPathExtension
                let displayName = entry.name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                let skipped = TestOutcome(
                    testName:           displayName ?? (baseName.isEmpty ? entry.script : baseName),
                    testClass:          nil,
                    tier:               entry.tier,
                    status:             .fail,
                    shortResult:        "Skipped: prerequisite '\(blockedBy)' did not pass",
                    longResult:         nil,
                    executionTimeMs:    0,
                    memoryUsageBytes:   nil,
                    attemptNumber:      job.attemptNumber,
                    isFirstPassSuccess: false
                )
                outcomes.append(skipped)
                continue
            }

            let scriptURL = testSetupDir.appendingPathComponent(entry.script)
            guard FileManager.default.fileExists(atPath: scriptURL.path) else {
                writeStructuredRunnerLog(event: "local_execution_error", fields: [
                    "runner_id": workerID,
                    "submission_id": job.submissionID,
                    "test_id": entry.script,
                    "error_type": "missing_script",
                    "error_message_summary": entry.script,
                ])
                continue
            }

            writeStructuredRunnerLog(event: "test_execution_start", fields: [
                "runner_id": workerID,
                "submission_id": job.submissionID,
                "test_id": entry.script,
            ])
            let output = await runner.run(
                script:           scriptURL,
                workDir:          testSetupDir,
                timeLimitSeconds: manifest.timeLimitSeconds
            )

            let isFirstAttempt = job.attemptNumber == 1
            let outcome = interpretOutput(output, entry: entry, attemptNumber: job.attemptNumber, isFirstAttempt: isFirstAttempt)
            outcomes.append(outcome)
            writeStructuredRunnerLog(event: output.timedOut ? "timeout" : "test_execution_end", fields: [
                "runner_id": workerID,
                "submission_id": job.submissionID,
                "test_id": normalizedTestID(for: outcome),
                "status": outcome.status.rawValue,
                "execution_ms": outcome.executionTimeMs,
            ])
            if outcome.status == .pass {
                passedScripts.insert(entry.script)
            }
        }

        let collection = makeCollection(
            outcomes: outcomes,
            warnings: normalizationWarnings,
            job: job,
            startedAt: jobStartedAt
        )
        do {
            try await reporter.report(collection)
            writeStructuredRunnerLog(event: "result_submission_succeeded", fields: [
                "runner_id": workerID,
                "submission_id": job.submissionID,
                "status": inferredCollectionStatus(collection).rawValue,
            ])
        } catch {
            writeStructuredRunnerLog(event: "result_submission_failed", fields: [
                "runner_id": workerID,
                "submission_id": job.submissionID,
                "error_type": String(describing: type(of: error)),
                "error_message_summary": String(describing: error),
            ])
            throw error
        }
    }

    // MARK: - Script output interpretation

    private func interpretOutput(
        _ output: ScriptOutput,
        entry: TestSuiteEntry,
        attemptNumber: Int,
        isFirstAttempt: Bool
    ) -> TestOutcome {
        let status: TestStatus
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

        let stderrText = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdoutText = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let longResult: String? = {
            guard status != .pass else { return stderrText.isEmpty ? nil : stderrText }
            var sections: [String] = []
            if !stdoutText.isEmpty {
                sections.append("stdout:\n\(stdoutText)")
            }
            if !stderrText.isEmpty {
                sections.append("stderr:\n\(stderrText)")
            }
            if sections.isEmpty { return nil }
            return sections.joined(separator: "\n\n")
        }()
        let baseName = (entry.script as NSString).deletingPathExtension
        let displayName = entry.name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }

        return TestOutcome(
            testName:           displayName ?? (baseName.isEmpty ? entry.script : baseName),
            testClass:          nil,
            tier:               entry.tier,
            status:             status,
            shortResult:        shortResult,
            longResult:         longResult,
            points:             entry.points,
            executionTimeMs:    output.executionTimeMs,
            memoryUsageBytes:   nil,
            attemptNumber:      attemptNumber,
            isFirstPassSuccess: isFirstAttempt && status == .pass
        )
    }

    // MARK: - Collection assembly

    private func makeCollection(
        outcomes: [TestOutcome],
        warnings: [String],
        job: Job,
        startedAt: Date
    ) -> TestOutcomeCollection {
        let passCount    = outcomes.filter { $0.status == .pass    }.count
        let failCount    = outcomes.filter { $0.status == .fail    }.count
        let errorCount   = outcomes.filter { $0.status == .error   }.count
        let timeoutCount = outcomes.filter { $0.status == .timeout }.count
        let totalMs      = outcomes.reduce(0) { $0 + $1.executionTimeMs }
        let totalPoints  = outcomes.reduce(0) { $0 + $1.points }
        let earnedPoints = outcomes.filter { $0.status == .pass }.reduce(0) { $0 + $1.points }

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
            totalPoints:     totalPoints,
            earnedPoints:    earnedPoints,
            warnings:        warnings,
            jobStartedAt:    startedAt,
            runnerVersion:   "shell-runner/1.0",
            timestamp:       Date()
        )
    }

    // MARK: - Subprocess helpers

    func download(url: URL, to destination: URL) async throws {
        let stage: RunnerRetryStage =
            destination.lastPathComponent == "submission.zip" ? .downloadSubmission : .downloadTestSetup

        try await withRunnerRetry(
            stage: stage,
            policy: downloadRetryPolicy,
            shouldRetry: { error in
                if let urlError = error as? URLError {
                    return .retryable(urlError.localizedDescription)
                }
                if let workerError = error as? WorkerDaemonError {
                    switch workerError {
                    case .httpDownloadFailure(let statusCode, let body):
                        return classifyHTTPRetry(statusCode: statusCode, body: body)
                    case .downloadFailed(let failedURL):
                        return .terminal("Failed to download \(failedURL.absoluteString)")
                    case .unzipFailed, .makeFailed:
                        return .terminal(String(describing: workerError))
                    }
                }
                return .terminal(String(describing: error))
            },
            onRetry: { context in
                await self.recordConnectionLostIfNeeded(
                    stage: context.stage,
                    message: context.message,
                    retryInSeconds: context.retryInSeconds
                )
                writeStructuredRunnerLog(event: "network_retry_scheduled", fields: [
                    "runner_id": self.workerID,
                    "failure_stage": context.stage.rawValue,
                    "attempt": context.attempt,
                    "max_attempts": context.maxAttempts,
                    "retry_in_seconds": context.retryInSeconds ?? 0,
                    "retryable": context.retryable,
                    "error_message_summary": context.message,
                ])
            }
        ) {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 5
            self.signer.sign(&request)
            let (tmpURL, response) = try await Self.downloadSession.download(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw WorkerDaemonError.downloadFailed(url)
            }
            guard http.statusCode == 200 else {
                throw WorkerDaemonError.httpDownloadFailure(
                    statusCode: http.statusCode,
                    body: "<download body unavailable>"
                )
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tmpURL, to: destination)
            await self.recordConnectionRestoredIfNeeded(stage: stage)
        }
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

    // extractNotebooksToCode is a module-level function (see below).

    private func reportProcessingFailure(job: Job, error: Error) async throws {
        let message = String(describing: error)
        let collection = TestOutcomeCollection(
            submissionID:    job.submissionID,
            testSetupID:     job.testSetupID,
            attemptNumber:   job.attemptNumber,
            buildStatus:     .failed,
            compilerOutput:  message,
            outcomes:        [],
            totalTests:      0,
            passCount:       0,
            failCount:       0,
            errorCount:      1,
            timeoutCount:    0,
            executionTimeMs: 0,
            warnings:        [],
            jobStartedAt:    Date(),
            runnerVersion:   "shell-runner/1.0",
            timestamp:       Date()
        )
        try await reporter.report(collection)
    }

    func sendHeartbeat() async throws {
        let payload = WorkerActivityPayload(
            workerID: workerID,
            hostname: ProcessInfo.processInfo.hostName,
            runnerVersion: ChickadeeVersion.current,
            maxConcurrentJobs: maxConcurrentJobs,
            activeJobs: activeJobs,
            profile: runnerProfile
        )
        do {
            try await reporter.heartbeat(payload)
            recordConnectionRestoredIfNeeded(stage: .heartbeat)
        } catch {
            recordConnectionLostIfNeeded(
                stage: .heartbeat,
                message: String(describing: error),
                retryInSeconds: nil
            )
            throw error
        }
    }

    private func recordConnectionLostIfNeeded(
        stage: RunnerRetryStage,
        message: String,
        retryInSeconds: Int?
    ) {
        if !serverConnectionLost {
            serverConnectionLost = true
            writeStructuredRunnerLog(event: "server_connection_lost", fields: [
                "runner_id": workerID,
                "failure_stage": stage.rawValue,
                "retryable": true,
                "retry_in_seconds": retryInSeconds ?? 0,
                "error_message_summary": message,
            ])
        } else if stage == .heartbeat, let retryInSeconds {
            writeStructuredRunnerLog(event: "heartbeat_retry_scheduled", fields: [
                "runner_id": workerID,
                "failure_stage": stage.rawValue,
                "retryable": true,
                "retry_in_seconds": retryInSeconds,
                "error_message_summary": message,
            ])
        }
    }

    private func recordConnectionRestoredIfNeeded(stage: RunnerRetryStage) {
        guard serverConnectionLost else { return }
        serverConnectionLost = false
        writeStructuredRunnerLog(event: "server_connection_restored", fields: [
            "runner_id": workerID,
            "failure_stage": stage.rawValue,
            "status": "ok",
        ])
    }

    private func normalizedTestID(for outcome: TestOutcome) -> String {
        let classPart = outcome.testClass?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return classPart.isEmpty ? outcome.testName : "\(classPart).\(outcome.testName)"
    }

    private func inferredCollectionStatus(_ collection: TestOutcomeCollection) -> RunnerJobStatus {
        if collection.timeoutCount > 0 { return .timeout }
        if collection.errorCount > 0 { return .error }
        if collection.buildStatus == .failed || collection.failCount > 0 { return .failed }
        return .passed
    }

    private func writeRRuntimeHelper(in directory: URL) throws {
        let rRuntimeURL = directory.appendingPathComponent("test_runtime.R")
        try testRuntimeR.write(to: rRuntimeURL, atomically: true, encoding: .utf8)
    }

    private func writePythonRuntimeHelpers(in directory: URL) throws {
        let runtimeURL = directory.appendingPathComponent("test_runtime.py")
        try testRuntimePy.write(to: runtimeURL, atomically: true, encoding: .utf8)

        // Python auto-imports sitecustomize (if present on sys.path), which
        // lets helpers be available without explicit imports in each test file.
        let sitecustomizeURL = directory.appendingPathComponent("sitecustomize.py")
        try sitecustomizePy.write(to: sitecustomizeURL, atomically: true, encoding: .utf8)
    }

    private func writeStudentModuleHint(in directory: URL, preferredFilename: String?) throws {
        let hintURL = directory.appendingPathComponent(".chickadee_student_module")
        if FileManager.default.fileExists(atPath: hintURL.path) {
            try FileManager.default.removeItem(at: hintURL)
        }

        guard let preferredFilename, !preferredFilename.isEmpty else { return }
        try preferredFilename.write(to: hintURL, atomically: true, encoding: .utf8)
    }
}

private func mergeDirectoryContents(from sourceDirectory: URL, into destinationDirectory: URL) throws {
    guard let enumerator = FileManager.default.enumerator(
        at: sourceDirectory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return
    }

    for case let sourceURL as URL in enumerator {
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { continue }
        let relativePath = sourceURL.path.replacingOccurrences(of: sourceDirectory.path + "/", with: "")
        let destinationURL = destinationDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }
}

private func legacyPreferredStudentModuleFilename(submissionFilename: String?) -> String? {
    guard let submissionFilename, !submissionFilename.isEmpty else { return nil }
    let submittedName = URL(fileURLWithPath: submissionFilename).lastPathComponent
    guard !submittedName.isEmpty else { return nil }

    let ext = URL(fileURLWithPath: submittedName).pathExtension.lowercased()
    if ext == "py" {
        return submittedName
    }
    if ext == "ipynb" {
        return (submittedName as NSString).deletingPathExtension + ".py"
    }
    return nil
}

private func shouldNormalizePythonSubmission(
    manifest: TestProperties,
    submissionFilename: String?,
    submissionDirectory: URL
) -> Bool {
    let requiredPythonFiles = manifest.requiredFiles.filter {
        URL(fileURLWithPath: $0).pathExtension.lowercased() == "py"
    }
    if !requiredPythonFiles.isEmpty { return true }

    if let submissionFilename {
        let ext = URL(fileURLWithPath: submissionFilename).pathExtension.lowercased()
        if ["py", "ipynb", "json"].contains(ext) {
            return true
        }
    }

    if manifest.testSuites.contains(where: { URL(fileURLWithPath: $0.script).pathExtension.lowercased() == "py" }) {
        return true
    }

    guard let enumerator = FileManager.default.enumerator(
        at: submissionDirectory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return false
    }
    for case let fileURL as URL in enumerator {
        let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else { continue }
        let ext = fileURL.pathExtension.lowercased()
        if ["py", "ipynb", "json"].contains(ext) {
            return true
        }
    }
    return false
}

// MARK: - Script result JSON (optional last-line protocol)

/// Scripts may optionally write this as their last stdout line to report a score.
private struct ScriptResultJSON: Decodable {
    let score: Double?
    let shortResult: String?
}

private let testRuntimePy = """
import inspect
import importlib.util
import json
import sys
import traceback
from pathlib import Path
from typing import Dict, List, Optional, Any


def _caller_file(depth: int = 3) -> Path:
    frame = inspect.stack()[depth]
    return Path(frame.filename)


def _first_comment_label() -> str:
    path = _caller_file()
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            s = line.strip()
            if not s:
                continue
            if s.startswith("#!") or s.startswith("# -*-"):
                continue
            if s.startswith("#"):
                label = s.lstrip("#").strip()
                return label if label else path.stem
            break
    except Exception:
        pass
    return path.stem


def _emit(payload: Dict[str, object]) -> None:
    print(json.dumps(payload, ensure_ascii=False))


def passed(message: Optional[str] = None):
    label = _first_comment_label()
    _emit({
        "shortResult": message or f"{label}: passed",
        "status": "pass",
        "test": label,
    })
    raise SystemExit(0)


def failed(message: str = "failed"):
    label = _first_comment_label()
    _emit({
        "shortResult": f"{label}: failed",
        "status": "fail",
        "test": label,
        "error": message,
    })
    raise SystemExit(1)


def errored(message: str = "error", err: Optional[Exception] = None):
    label = _first_comment_label()
    summary = message.strip() if isinstance(message, str) and message.strip() else "error"
    payload = {
        "shortResult": f"{label}: {summary}",
        "status": "error",
        "test": label,
        "error": summary,
    }
    if err is not None:
        payload["exception"] = repr(err)
        payload["traceback"] = traceback.format_exc()
    _emit(payload)
    raise SystemExit(2)


def _candidate_student_files() -> List[Path]:
    cwd = Path(".")
    files: List[Path] = []
    for p in cwd.glob("*.py"):
        name = p.name
        if name in {"test_runtime.py", "sitecustomize.py", "nb_to_py.py"}:
            continue
        lower = name.lower()
        if lower.startswith("publictest") or lower.startswith("secrettest") or lower.startswith("releasetest"):
            continue
        files.append(p)
    return sorted(files, key=_student_file_sort_key)


def _student_file_sort_key(path: Path):
    lower = path.name.lower()
    if lower == "assignment.py":
        return (90, lower)
    if lower in {"solution.py", "submission.py"}:
        return (0, lower)
    return (10, lower)


def _preferred_student_module() -> Optional[Path]:
    hint = Path(".chickadee_student_module")
    if not hint.exists():
        return None
    try:
        raw = hint.read_text(encoding="utf-8").strip()
    except Exception:
        return None
    if not raw:
        return None
    preferred = Path(raw).name
    if not preferred.endswith(".py"):
        return None
    path = Path(preferred)
    return path if path.exists() else None


def _module_name_for_path(path: Path) -> str:
    stem = path.stem
    safe = "".join(ch if (ch.isalnum() or ch == "_") else "_" for ch in stem)
    if not safe:
        safe = "student"
    if safe[0].isdigit():
        safe = f"m_{safe}"
    return f"student_{safe}"


def _ordered_student_files() -> List[Path]:
    preferred = _preferred_student_module()
    # When a specific submission module is hinted, only evaluate that file.
    # This avoids accidentally resolving functions from setup-side helpers
    # like solution.py/assignment.py.
    if preferred is not None:
        return [preferred]
    return _candidate_student_files()


_loaded_student_modules: Optional[Dict[str, Any]] = None
_loaded_student_order: List[str] = []
_student_module_errors: Dict[str, str] = {}


def load_student_modules(force_reload: bool = False) -> Dict[str, Any]:
    global _loaded_student_modules, _loaded_student_order, _student_module_errors
    if _loaded_student_modules is not None and not force_reload:
        return _loaded_student_modules

    modules: Dict[str, Any] = {}
    order: List[str] = []
    errors: Dict[str, str] = {}

    for path in _ordered_student_files():
        key = path.name
        try:
            module_name = _module_name_for_path(path)
            spec = importlib.util.spec_from_file_location(module_name, path)
            if spec is None or spec.loader is None:
                errors[key] = "Could not create import spec."
                continue
            module = importlib.util.module_from_spec(spec)
            sys.modules[module_name] = module
            spec.loader.exec_module(module)
            modules[key] = module
            order.append(key)
        except Exception:
            errors[key] = traceback.format_exc()

    _loaded_student_modules = modules
    _loaded_student_order = order
    _student_module_errors = errors
    return modules


def student_module_errors() -> Dict[str, str]:
    return _student_module_errors


def student_module_names_in_load_order() -> List[str]:
    return list(_loaded_student_order)


def load_student_module():
    modules = load_student_modules()
    if not _loaded_student_order:
        return None
    return modules.get(_loaded_student_order[0])


def require_function(name: str):
    modules = load_student_modules()
    for key in _loaded_student_order:
        module = modules.get(key)
        if module is None:
            continue
        fn = getattr(module, name, None)
        if fn is not None and callable(fn):
            return fn

    if not modules:
        errors = student_module_errors()
        if errors:
            first_name = next(iter(errors.keys()))
            errored(
                "Could not load any student Python module from submission. "
                f"First load failure came from '{first_name}'."
            )
        errored("Could not load a student Python module from submission.")

    errored(f"Required function '{name}' was not found or is not callable in loaded student modules.")
"""

private let sitecustomizePy = """
import builtins
import test_runtime as _tr

builtins.passed = _tr.passed
builtins.failed = _tr.failed
builtins.errored = _tr.errored
builtins.require_function = _tr.require_function

_student_modules = _tr.load_student_modules()
builtins.student_modules = _student_modules
_student_module = _tr.load_student_module()
builtins.student_module = _student_module
for _module_name in _tr.student_module_names_in_load_order():
    _module = _student_modules.get(_module_name)
    if _module is None:
        continue
    for _name, _value in vars(_module).items():
        if _name.startswith("_"):
            continue
        if callable(_value) and not hasattr(builtins, _name):
            setattr(builtins, _name, _value)
"""

// MARK: - R test runtime

// Injected into every test working directory alongside the Python helpers.
// Hand-formatted JSON output avoids any dependency on jsonlite or other packages
// that may not be present on a bare R install.
//
// Mirrors the canonical source in Tools/runner-support/test_runtime.R.
// Keep the two in sync when making changes here.
let testRuntimeR = #"""
# test_runtime.R — Chickadee R test helper library.
# Source at the top of each R test script: source("test_runtime.R")
#
# API:
#   passed(message = NULL)     — exit 0  (pass)
#   failed(message = "failed") — exit 1  (fail)
#   errored(message = "error") — exit 2  (error)
#
# No external package dependencies; JSON is hand-formatted so this works
# on bare R installs without jsonlite.

.chickadee_json_str <- function(x) {
    x <- as.character(x)
    x <- gsub("\\\\", "\\\\\\\\", x, fixed = TRUE)
    x <- gsub('"',    '\\\\"',    x, fixed = TRUE)
    x <- gsub("\n",   "\\\\n",    x, fixed = TRUE)
    x <- gsub("\r",   "\\\\r",    x, fixed = TRUE)
    x <- gsub("\t",   "\\\\t",    x, fixed = TRUE)
    paste0('"', x, '"')
}

.chickadee_label <- function() {
    args  <- commandArgs(trailingOnly = FALSE)
    fargs <- args[startsWith(args, "--file=")]
    if (length(fargs) > 0L) {
        path <- sub("^--file=", "", fargs[[1L]])
        return(tools::file_path_sans_ext(basename(path)))
    }
    "test"
}

.chickadee_emit <- function(status, short_result, error = NULL) {
    label <- .chickadee_label()
    parts <- c(
        paste0('"status":',      .chickadee_json_str(status)),
        paste0('"shortResult":', .chickadee_json_str(short_result)),
        paste0('"test":',        .chickadee_json_str(label))
    )
    if (!is.null(error)) {
        parts <- c(parts, paste0('"error":', .chickadee_json_str(as.character(error))))
    }
    cat(paste0("{", paste(parts, collapse = ","), "}\n"))
}

passed <- function(message = NULL) {
    label <- .chickadee_label()
    msg   <- if (!is.null(message)) as.character(message) else paste0(label, ": passed")
    .chickadee_emit("pass", msg)
    quit(status = 0L, save = "no")
}

failed <- function(message = "failed") {
    label <- .chickadee_label()
    msg   <- as.character(message)
    .chickadee_emit("fail", paste0(label, ": ", msg), error = msg)
    quit(status = 1L, save = "no")
}

errored <- function(message = "error") {
    label <- .chickadee_label()
    msg   <- as.character(message)
    .chickadee_emit("error", paste0(label, ": ", msg), error = msg)
    quit(status = 2L, save = "no")
}
"""#

// MARK: - Notebook extraction

/// Extract code cells from all .ipynb notebooks in `directory` into .py or .R source files.
///
/// This replaces the former runner-support/Makefile prep step with a pure-Swift
/// implementation. The .ipynb format is plain JSON — no `make`, Python, or external
/// tools are required. Kernel language detection mirrors the logic in
/// TestSetupRoutes.normalizeNotebookForJupyterLite() and browser-runner.js.
///
/// Module-level (not private) so WorkerTests can exercise it directly.
func extractNotebooksToCode(in directory: URL) throws {
    let items = (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )) ?? []

    for item in items where item.pathExtension.lowercased() == "ipynb" {
        // Every .ipynb in the directory is extracted to .py (or .R).  The
        // starter template notebook is already removed by process() before
        // this function runs (driven by manifest.starterNotebook), so the
        // only notebooks remaining are the student/canonical submission and
        // any instructor-provided helper notebooks that should be converted.
        guard
            let data     = try? Data(contentsOf: item),
            let notebook = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let cells    = notebook["cells"] as? [[String: Any]]
        else { continue }

        // Detect kernel language: ir/r/webr → R, everything else → Python.
        let language: String = {
            if let meta = notebook["metadata"] as? [String: Any] {
                if let ks = meta["kernelspec"] as? [String: Any],
                   let name = (ks["name"] as? String)?.lowercased() {
                    if name == "ir" || name == "r" || name == "webr" { return "r" }
                }
                if let li = meta["language_info"] as? [String: Any],
                   (li["name"] as? String)?.lowercased() == "r" { return "r" }
            }
            return "python"
        }()

        let ext    = language == "r" ? "R" : "py"
        let stem   = item.deletingPathExtension().lastPathComponent
        let outURL = directory.appendingPathComponent("\(stem).\(ext)")

        var output = "# Generated from \(item.lastPathComponent)\n\n"
        for cell in cells {
            guard cell["cell_type"] as? String == "code" else { continue }
            let raw: String
            if let arr = cell["source"] as? [String] {
                raw = arr.joined()
            } else if let str = cell["source"] as? String {
                raw = str
            } else { continue }

            // Mirror Python's rstrip(): strip trailing whitespace/newlines.
            var src = raw
            while src.last?.isWhitespace == true { src.removeLast() }
            guard !src.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            output += src + "\n\n"
        }

        try output.write(to: outURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - Helpers

private extension TestStatus {
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
        // Lower bound is the initial interval so next() never returns zero,
        // which would defeat the purpose of backing off.
        let lo = Double(initial.components.seconds)
        let hi = Double(doubled)
        return Duration.seconds(Double.random(in: lo...hi))
    }

    mutating func reset() {
        current = initial
    }
}

// MARK: - Errors

enum WorkerDaemonError: Error, LocalizedError {
    case downloadFailed(URL)
    case httpDownloadFailure(statusCode: Int, body: String)
    case unzipFailed(URL)
    case makeFailed(String?)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let url):  return "Failed to download \(url)"
        case .httpDownloadFailure(let statusCode, let body):
            return "HTTP \(statusCode) while downloading artifacts: \(body)"
        case .unzipFailed(let url):     return "Failed to unzip \(url.lastPathComponent)"
        case .makeFailed(let target):   return "make \(target ?? "") failed"
        }
    }
}
