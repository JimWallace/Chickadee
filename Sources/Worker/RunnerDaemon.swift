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
        var backoff = ExponentialBackoff(
            initial: .milliseconds(runnerEnvironmentInt("RUNNER_RETRY_BASE_DELAY_MS", default: 1000)),
            max: .milliseconds(runnerEnvironmentInt("RUNNER_RETRY_MAX_DELAY_MS", default: 30_000))
        )
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
            case 3:  status = .fail  // chickadee.py (Marmoset) uses exit 3 for "failed"
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

    // extractNotebooksToCode is a module-level function (NotebookExtractor.swift).

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
