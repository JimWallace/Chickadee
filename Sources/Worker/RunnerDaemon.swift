// Worker/RunnerDaemon.swift
//
// The WorkerDaemon actor: poll/retry machinery, artifact downloads,
// heartbeats, and connection-loss tracking.  The CLI entry point lives in
// WorkerCommand.swift, structured logging + stage timings in
// RunnerStructuredLog.swift, and the free staging helpers + error enum in
// SubmissionStaging.swift (June 2026 audit split).

import Core
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession, URLRequest on Linux
#endif

enum RunnerJobStatus: String {
    case passed
    case failed
    case error
    case timeout
}

// MARK: - WorkerDaemon actor

actor WorkerDaemon {
    static let downloadSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        // Request timeout is per-idle-interval (resets whenever bytes arrive);
        // resource timeout caps the WHOLE transfer. The old 15 s resource cap
        // meant a large setup zip on a slow link could *never* download — a
        // deterministic failure no retry can fix (June 2026 audit). 10 min is
        // a backstop against truly hung transfers, not a tuning knob.
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 600
        return URLSession(configuration: cfg)
    }()

    let poller: any JobPolling
    let reporter: any Reporting
    let runner: any ScriptRunner
    let apiBaseURL: URL
    let workerID: String
    let signer: WorkerRequestSigner
    let maxConcurrentJobs: Int
    let runnerProfile: RunnerCapabilityProfile?
    let downloadRetryPolicy: RunnerRetryPolicy
    let testSetupCache: TestSetupCache
    let config: RunnerDaemonConfig
    var serverConnectionLost = false
    var activeJobs = 0

    init(
        poller: any JobPolling,
        reporter: any Reporting,
        runner: any ScriptRunner,
        apiBaseURL: URL,
        workerID: String,
        workerSecret: String,
        maxConcurrentJobs: Int,
        runnerProfile: RunnerCapabilityProfile? = nil,
        downloadRetryPolicy: RunnerRetryPolicy = .download(),
        testSetupCache: TestSetupCache = TestSetupCache(),
        config: RunnerDaemonConfig = .loadFromEnvironment()
    ) {
        self.poller = poller
        self.reporter = reporter
        self.runner = runner
        self.apiBaseURL = apiBaseURL
        self.workerID = workerID
        self.signer = WorkerRequestSigner(sharedSecret: workerSecret, workerID: workerID)
        self.maxConcurrentJobs = maxConcurrentJobs
        self.runnerProfile = runnerProfile
        self.downloadRetryPolicy = downloadRetryPolicy
        self.testSetupCache = testSetupCache
        self.config = config
    }

    func run() async throws {
        defer {
            writeStructuredRunnerLog(
                event: "runner_shutdown",
                fields: [
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
            initial: .milliseconds(config.retryBaseDelayMs),
            max: .milliseconds(config.retryMaxDelayMs)
        )
        while !Task.isCancelled {
            do {
                try await runPollCycle(slot: slot, backoff: &backoff)
            } catch JobPollerError.duplicateWorkerID(let message) {
                try await handleRetryablePollError(
                    slot: slot,
                    status: "duplicate_worker_id",
                    message: message,
                    httpStatus: nil,
                    backoff: &backoff
                )
            } catch JobPollerError.transportError(let underlying) {
                // Server is unreachable (connection refused, DNS failure, etc.).
                // Apply the same exponential backoff used for the no-job poll and
                // keep retrying so the runner survives server restarts automatically.
                try await handleRetryablePollError(
                    slot: slot,
                    status: "transport_error",
                    message: underlying.localizedDescription,
                    httpStatus: nil,
                    backoff: &backoff
                )
            } catch JobPollerError.httpError(let statusCode, let body) {
                try await handleHTTPPollError(
                    slot: slot,
                    statusCode: statusCode,
                    body: body,
                    backoff: &backoff
                )
            } catch JobPollerError.unexpectedResponse {
                try await handleRetryablePollError(
                    slot: slot,
                    status: "unexpected_response",
                    message: "unexpected response from API server",
                    httpStatus: nil,
                    backoff: &backoff
                )
            } catch JobPollerError.decodingFailed(let underlying) {
                // Schema mismatch between server and worker — retryable (it
                // resolves when the lagging side is upgraded), but logged under
                // its own status so it can't be mistaken for a network problem.
                try await handleRetryablePollError(
                    slot: slot,
                    status: "job_decode_failed",
                    message: String(describing: underlying),
                    httpStatus: nil,
                    backoff: &backoff
                )
            }
        }
    }

    /// Single iteration of the poll loop: emit a `poll_cycle_start` log, ask
    /// the poller for work, and either run the job (handling per-job errors
    /// inline) or sleep `backoff.next()` if no job was returned.
    private func runPollCycle(slot: Int, backoff: inout ExponentialBackoff) async throws {
        let currentActiveJobs = activeJobs
        writeStructuredRunnerLog(
            event: "poll_cycle_start",
            fields: [
                "runner_id": workerID,
                "slot": slot,
                "runner_active_jobs": currentActiveJobs,
                "max_jobs": maxConcurrentJobs,
                "api_base_url": apiBaseURL.absoluteString,
            ])
        if let job = try await poller.requestJob(activeJobs: currentActiveJobs) {
            recordConnectionRestoredIfNeeded(stage: .poll)
            backoff.reset()
            writeStructuredRunnerLog(
                event: "poll_cycle_end",
                fields: [
                    "runner_id": workerID,
                    "slot": slot,
                    "status": "job_assigned",
                    "submission_id": job.submissionID,
                ])
            await runAssignedJob(job)
        } else {
            writeStructuredRunnerLog(
                event: "poll_cycle_end",
                fields: [
                    "runner_id": workerID,
                    "slot": slot,
                    "status": "no_job",
                ])
            let delay = backoff.next()
            try await Task.sleep(for: delay)
        }
    }

    /// Runs `process(job)` and reports any local-execution failure back to
    /// the server. Extracted so the outer loop reads as a single statement.
    private func runAssignedJob(_ job: Job) async {
        do {
            try await process(job)
        } catch {
            writeStructuredRunnerLog(
                event: "local_execution_error",
                fields: [
                    "runner_id": workerID,
                    "submission_id": job.submissionID,
                    "error_type": String(describing: type(of: error)),
                    "error_message_summary": String(describing: error),
                ])
            try? await reportProcessingFailure(job: job, error: error)
        }
    }

    /// Shared retry/backoff handling for every retryable poll-side error
    /// (duplicate worker id, transport, retryable HTTP, unexpected response).
    /// Records the connection-lost transition, logs `poll_cycle_end` with
    /// the appropriate status and `retry_in_seconds`, then sleeps.
    private func handleRetryablePollError(
        slot: Int,
        status: String,
        message: String,
        httpStatus: Int?,
        backoff: inout ExponentialBackoff
    ) async throws {
        let delay = backoff.next()
        let seconds = delay.components.seconds
        recordConnectionLostIfNeeded(
            stage: .poll,
            message: message,
            retryInSeconds: Int(seconds)
        )
        var fields: [String: Any] = [
            "runner_id": workerID,
            "slot": slot,
            "status": status,
            "failure_stage": RunnerRetryStage.poll.rawValue,
            "retryable": true,
            "error_message_summary": message,
            "retry_in_seconds": seconds,
        ]
        if let httpStatus { fields["http_status"] = httpStatus }
        writeStructuredRunnerLog(event: "poll_cycle_end", fields: fields)
        try await Task.sleep(for: delay)
    }

    /// HTTP-specific dispatch: classify the response, then either reuse the
    /// shared retry handler or log a terminal failure and rethrow.
    private func handleHTTPPollError(
        slot: Int,
        statusCode: Int,
        body: String,
        backoff: inout ExponentialBackoff
    ) async throws {
        let disposition = classifyPollHTTPRetry(statusCode: statusCode, body: body)
        switch disposition {
        case .retryable(let message):
            try await handleRetryablePollError(
                slot: slot,
                status: "http_error",
                message: message,
                httpStatus: statusCode,
                backoff: &backoff
            )
        case .terminal(let message):
            writeStructuredRunnerLog(
                event: "poll_cycle_end",
                fields: [
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
                    case .makeFailed, .makeTimedOut, .insufficientDiskSpace, .unsafePersonalizedFilename:
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
                writeStructuredRunnerLog(
                    event: "network_retry_scheduled",
                    fields: [
                        "runner_id": self.workerID,
                        "failure_stage": context.stage.rawValue,
                        "attempt": context.attempt,
                        "max_attempts": context.maxAttempts,
                        "retry_in_seconds": context.retryInSeconds ?? 0,
                        "retryable": context.retryable,
                        "error_message_summary": context.message,
                    ])
            },
            operation: {
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
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: tmpURL, to: destination)
                await self.recordConnectionRestoredIfNeeded(stage: stage)
            }
        )
    }

    // `unzip(_:to:)` was removed in v0.4.178; job processing now calls
    // `extractZipArchive(zipPath:into:)` from the `Core` library, which
    // shares the same lock + EFAULT-retry as the server-side zip helpers.

    /// Runs the optional pre-test `make` step through the same bounded
    /// process machinery as test scripts (#1107). The step executes AFTER the
    /// student submission is merged into the workspace, so a submission with
    /// a hung `make` used to block a cooperative-pool thread and a job slot
    /// forever (`waitUntilExit()` on the actor, no time limit, no kill) — the
    /// exact starvation `ScriptRunner` was hardened against for test scripts.
    /// Now it gets the timeout + process kill + capped output capture for
    /// free, a timeout maps to `buildStatus: failed`, and the captured
    /// output rides the error into `compilerOutput` so the instructor can
    /// see why the build failed. Like test scripts, `make` inherits only the
    /// allowlisted environment (no worker secrets).
    func runMake(in directory: URL, target: String?) async throws {
        let timeLimitSeconds = max(1, config.makeTimeoutSeconds)
        let launch = ScriptLaunch(
            executablePath: "/usr/bin/make",
            arguments: target.map { [$0] } ?? [],
            env: mergedScriptEnvironment(overrides: [:])
        )
        let output = await executeScriptLaunch(
            launch,
            workDir: directory,
            timeLimitSeconds: timeLimitSeconds,
            launchErrorPrefix: "Failed to launch make"
        )
        if output.timedOut {
            throw WorkerDaemonError.makeTimedOut(target: target, limitSeconds: timeLimitSeconds)
        }
        guard output.exitCode == 0 else {
            let detail = [output.stderr, output.stdout]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw WorkerDaemonError.makeFailed(
                target: target, detail: detail.isEmpty ? nil : detail)
        }
    }

    // extractNotebooksToCode is a module-level function (NotebookExtractor.swift).

    func reportProcessingFailure(job: Job, error: Error) async throws {
        let message = String(describing: error)
        let collection = TestOutcomeCollection(
            submissionID: job.submissionID,
            testSetupID: job.testSetupID,
            attemptNumber: job.attemptNumber,
            buildStatus: .failed,
            compilerOutput: message,
            outcomes: [],
            totalTests: 0,
            passCount: 0,
            failCount: 0,
            errorCount: 1,
            timeoutCount: 0,
            executionTimeMs: 0,
            warnings: [],
            jobStartedAt: Date(),
            runnerVersion: ChickadeeVersion.current,
            timestamp: Date()
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

    func recordConnectionLostIfNeeded(
        stage: RunnerRetryStage,
        message: String,
        retryInSeconds: Int?
    ) {
        if !serverConnectionLost {
            serverConnectionLost = true
            writeStructuredRunnerLog(
                event: "server_connection_lost",
                fields: [
                    "runner_id": workerID,
                    "failure_stage": stage.rawValue,
                    "retryable": true,
                    "retry_in_seconds": retryInSeconds ?? 0,
                    "error_message_summary": message,
                ])
        } else if stage == .heartbeat, let retryInSeconds {
            writeStructuredRunnerLog(
                event: "heartbeat_retry_scheduled",
                fields: [
                    "runner_id": workerID,
                    "failure_stage": stage.rawValue,
                    "retryable": true,
                    "retry_in_seconds": retryInSeconds,
                    "error_message_summary": message,
                ])
        }
    }

    func recordConnectionRestoredIfNeeded(stage: RunnerRetryStage) {
        guard serverConnectionLost else { return }
        serverConnectionLost = false
        writeStructuredRunnerLog(
            event: "server_connection_restored",
            fields: [
                "runner_id": workerID,
                "failure_stage": stage.rawValue,
                "status": "ok",
            ])
    }

    func inferredCollectionStatus(_ collection: TestOutcomeCollection) -> RunnerJobStatus {
        if collection.timeoutCount > 0 { return .timeout }
        if collection.errorCount > 0 { return .error }
        if collection.buildStatus == .failed || collection.failCount > 0 { return .failed }
        return .passed
    }

    func writeRRuntimeHelper(in directory: URL) throws {
        let rRuntimeURL = directory.appendingPathComponent("test_runtime.R")
        try testRuntimeR.write(to: rRuntimeURL, atomically: true, encoding: .utf8)
    }

    func writePythonRuntimeHelpers(in directory: URL) throws {
        let runtimeURL = directory.appendingPathComponent("test_runtime.py")
        try testRuntimePy.write(to: runtimeURL, atomically: true, encoding: .utf8)

        // Python auto-imports sitecustomize (if present on sys.path), which
        // lets helpers be available without explicit imports in each test file.
        let sitecustomizeURL = directory.appendingPathComponent("sitecustomize.py")
        try sitecustomizePy.write(to: sitecustomizeURL, atomically: true, encoding: .utf8)
    }

    func writeStudentModuleHint(in directory: URL, preferredFilename: String?) throws {
        let hintURL = directory.appendingPathComponent(".chickadee_student_module")
        try? FileManager.default.removeItem(at: hintURL)

        guard let preferredFilename, !preferredFilename.isEmpty else { return }
        try preferredFilename.write(to: hintURL, atomically: true, encoding: .utf8)
    }
}
