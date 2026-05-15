// Worker/RunnerDaemon.swift

import ArgumentParser
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

struct JobStageTimings {
    private var values: [String: Int] = [:]
    var testSetupCacheHit: Bool?

    mutating func measureSync<T>(_ stage: String, operation: () throws -> T) rethrows -> T {
        let start = Date()
        let result = try operation()
        values[stage] = millisecondsSince(start)
        return result
    }

    mutating func record(_ stage: String, milliseconds: Int) {
        values[stage] = milliseconds
    }

    func fields() -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in values {
            result["\(key)_ms"] = value
        }
        if let testSetupCacheHit {
            result["test_setup_cache_hit"] = testSetupCacheHit
        }
        return result
    }

    func value(for stage: String) -> Int? {
        values[stage]
    }

    func asWorkerExecutionStageTimings() -> WorkerExecutionStageTimings {
        WorkerExecutionStageTimings(
            workdirSetupMs: value(for: "workdir_setup"),
            submissionDirSetupMs: value(for: "submission_dir_setup"),
            submissionDownloadMs: value(for: "submission_download"),
            testSetupAcquireMs: value(for: "test_setup_acquire"),
            submissionUnpackMs: value(for: "submission_unpack"),
            starterCleanupMs: value(for: "starter_cleanup"),
            submissionPrepareMs: value(for: "submission_prepare"),
            makeStepMs: value(for: "make_step"),
            runtimeHelperSetupMs: value(for: "runtime_helper_setup"),
            testExecutionMs: value(for: "test_execution"),
            testSetupCacheHit: testSetupCacheHit
        )
    }

    private func millisecondsSince(_ start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}

private func writeToStandardError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

func writeStructuredRunnerLog(event: String, fields: [String: Any]) {
    var payload = fields
    payload["timestamp"] = ISO8601DateFormatter().string(from: Date())
    payload["event"] = event
    guard JSONSerialization.isValidJSONObject(payload),
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    else {
        writeToStandardError(
            "{\"event\":\"\(event)\",\"timestamp\":\"\(ISO8601DateFormatter().string(from: Date()))\"}\n")
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

    @Option(
        name: .long,
        help:
            "Directory used for the runner test-setup cache (default: /tmp/chickadee-runner-cache; env: RUNNER_TEST_SETUP_CACHE_DIR)"
    )
    var testSetupCacheDir: String?

    mutating func run() async throws {
        guard let baseURL = URL(string: apiBaseURL) else {
            writeToStandardError("Error: invalid --api-base-url '\(apiBaseURL)'\n")
            throw ExitCode.failure
        }

        let env = ProcessInfo.processInfo.environment
        let config = RunnerDaemonConfig.loadFromEnvironment(env)
        let runnerProfile = await RunnerProfileDetector(discoveryEnabled: config.capabilityDiscoveryEnabled).detect()
        guard
            let effectiveWorkerSecret = resolveWorkerSharedSecret(
                cliWorkerSecret: workerSecret,
                environment: env
            )
        else {
            writeToStandardError("Error: missing runner secret. Use --worker-secret or set RUNNER_SHARED_SECRET.\n")
            throw ExitCode.failure
        }

        let poller = JobPoller(
            apiBaseURL: baseURL,
            workerID: workerID,
            workerSecret: effectiveWorkerSecret,
            maxConcurrentJobs: maxJobs,
            profile: runnerProfile
        )
        let reporter = Reporter(
            apiBaseURL: baseURL,
            workerID: workerID,
            workerSecret: effectiveWorkerSecret,
            heartbeatRetryPolicy: .heartbeat(config: config),
            resultUploadRetryPolicy: .resultUpload(config: config)
        )
        let runner: any ScriptRunner = sandbox ? SandboxedScriptRunner() : UnsandboxedScriptRunner()

        let cacheDirPath =
            testSetupCacheDir
            ?? config.testSetupCacheDir
            ?? TestSetupCache.defaultCacheRoot.path
        let testSetupCache = TestSetupCache(cacheRoot: URL(fileURLWithPath: cacheDirPath))

        let daemon = WorkerDaemon(
            poller: poller,
            reporter: reporter,
            runner: runner,
            apiBaseURL: baseURL,
            workerID: workerID,
            workerSecret: effectiveWorkerSecret,
            maxConcurrentJobs: maxJobs,
            runnerProfile: runnerProfile,
            downloadRetryPolicy: .download(config: config),
            testSetupCache: testSetupCache,
            config: config
        )

        let sandboxLabel = sandbox ? "sandboxed" : "unsandboxed"
        writeStructuredRunnerLog(
            event: "runner_startup",
            fields: [
                "runner_id": workerID,
                "status": "starting",
            ])
        writeStructuredRunnerLog(
            event: "runner_configuration",
            fields: [
                "runner_id": workerID,
                "api_base_url": apiBaseURL,
                "max_jobs": maxJobs,
                "sandbox_mode": sandboxLabel,
                "test_setup_cache_dir": cacheDirPath,
            ])
        if let runnerProfile {
            writeStructuredRunnerLog(
                event: "runner_profile_detected",
                fields: [
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
        let raw = try? String(contentsOfFile: path, encoding: .utf8)
    else {
        return nil
    }

    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

// MARK: - WorkerDaemon actor

actor WorkerDaemon {
    static let downloadSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 15
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
            } catch JobPollerError.duplicateWorkerID(let message) {
                let delay = backoff.next()
                let seconds = delay.components.seconds
                recordConnectionLostIfNeeded(
                    stage: .poll,
                    message: message,
                    retryInSeconds: Int(seconds)
                )
                writeStructuredRunnerLog(
                    event: "poll_cycle_end",
                    fields: [
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
                writeStructuredRunnerLog(
                    event: "poll_cycle_end",
                    fields: [
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
                let disposition = classifyPollHTTPRetry(statusCode: statusCode, body: body)
                switch disposition {
                case .retryable(let message):
                    let delay = backoff.next()
                    let seconds = delay.components.seconds
                    recordConnectionLostIfNeeded(
                        stage: .poll,
                        message: message,
                        retryInSeconds: Int(seconds)
                    )
                    writeStructuredRunnerLog(
                        event: "poll_cycle_end",
                        fields: [
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
            } catch JobPollerError.unexpectedResponse {
                let delay = backoff.next()
                let seconds = delay.components.seconds
                recordConnectionLostIfNeeded(
                    stage: .poll,
                    message: "unexpected response from API server",
                    retryInSeconds: Int(seconds)
                )
                writeStructuredRunnerLog(
                    event: "poll_cycle_end",
                    fields: [
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
                    case .unzipFailed, .makeFailed, .insufficientDiskSpace:
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
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tmpURL, to: destination)
            await self.recordConnectionRestoredIfNeeded(stage: stage)
        }
    }

    nonisolated func unzip(_ zipFile: URL, to directory: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-q", "-o", zipFile.path, "-d", directory.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw WorkerDaemonError.unzipFailed(zipFile)
        }
    }

    func runMake(in directory: URL, target: String?) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/make")
        proc.arguments = target.map { [$0] } ?? []
        proc.currentDirectoryURL = directory
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw WorkerDaemonError.makeFailed(target)
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

    func normalizedTestID(for outcome: TestOutcome) -> String {
        let classPart = outcome.testClass?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return classPart.isEmpty ? outcome.testName : "\(classPart).\(outcome.testName)"
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

/// Returns the free space (megabytes) reported by the filesystem holding
/// `path`. Returns nil only if the OS refuses to answer; callers should
/// treat that as "skip the precheck and let downstream errors surface".
func freeSpaceMB(at path: URL) -> Int? {
    guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path.path),
        let free = attrs[.systemFreeSize] as? NSNumber
    else {
        return nil
    }
    return Int(truncating: free) / (1024 * 1024)
}

/// Walks `directory` (skipping hidden files) and sums the size of every
/// regular file. Returns nil if the directory doesn't exist or can't be
/// enumerated — useful so telemetry can distinguish "0 bytes" (empty
/// workspace) from "couldn't measure" (cleanup already ran, etc.). Used
/// as a proxy for a job's peak workspace footprint — accurate enough for
/// the monotonically-growing workDir we care about.
func directorySizeBytes(at directory: URL) -> Int? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
        isDirectory.boolValue
    else {
        return nil
    }
    guard
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
    else {
        return nil
    }
    var total: Int = 0
    for case let url as URL in enumerator {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true,
            let size = values.fileSize
        else { continue }
        total += size
    }
    return total
}

func mergeDirectoryContents(from sourceDirectory: URL, into destinationDirectory: URL) throws {
    // Resolve symlinks once on the source root so that the prefix comparison
    // below works even when callers pass paths through `/var` vs `/private/var`
    // (macOS) or otherwise-aliased mounts.
    let sourceRoot = sourceDirectory.resolvingSymlinksInPath().standardizedFileURL
    let sourceRootComponents = sourceRoot.pathComponents

    guard
        let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
    else {
        return
    }

    for case let sourceURL as URL in enumerator {
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { continue }

        let resolved = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        let entryComponents = resolved.pathComponents
        guard entryComponents.count > sourceRootComponents.count,
            Array(entryComponents.prefix(sourceRootComponents.count)) == sourceRootComponents
        else {
            // Enumerator handed us something outside the source root — skip
            // rather than write to an unintended destination.
            continue
        }
        let relativeComponents = Array(entryComponents.dropFirst(sourceRootComponents.count))

        var destinationURL = destinationDirectory
        for component in relativeComponents {
            destinationURL.appendPathComponent(component)
        }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }
}

func legacyPreferredStudentModuleFilename(submissionFilename: String?) -> String? {
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

func stagedSubmissionDestination(
    submissionDirectory: URL,
    submittedFilename: String
) -> URL {
    let basename = URL(fileURLWithPath: submittedFilename).lastPathComponent
    let safeName = basename.isEmpty ? "submission.bin" : basename
    return submissionDirectory.appendingPathComponent(safeName)
}

func shouldNormalizePythonSubmission(
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

    guard
        let enumerator = FileManager.default.enumerator(
            at: submissionDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
    else {
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

func testSetupCacheKey(for job: Job) -> String {
    let manifestBytes = (try? ManifestCodec.encoder.encode(job.manifest)) ?? Data()
    var material = Data()
    material.append(Data(job.testSetupID.utf8))
    material.append(0)
    material.append(Data(job.testSetupURL.absoluteString.utf8))
    material.append(0)
    material.append(manifestBytes)
    let digest = sha256HexDigest(material)
    return "\(job.testSetupID)-\(digest.prefix(16))"
}

// MARK: - Script result JSON (optional last-line protocol)

/// Scripts may optionally write this as their last stdout line to report a score.
struct ScriptResultJSON: Decodable {
    let score: Double?
    let shortResult: String?
}

// MARK: - Helpers

extension TestStatus {
    var defaultShortResult: String {
        switch self {
        case .pass: return "passed"
        case .fail: return "failed"
        case .error: return "error"
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
    case insufficientDiskSpace(path: String, freeMB: Int, requiredMB: Int)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let url): return "Failed to download \(url)"
        case .httpDownloadFailure(let statusCode, let body):
            return "HTTP \(statusCode) while downloading artifacts: \(body)"
        case .unzipFailed(let url): return "Failed to unzip \(url.lastPathComponent)"
        case .makeFailed(let target): return "make \(target ?? "") failed"
        case .insufficientDiskSpace(let path, let freeMB, let requiredMB):
            return
                "Runner workspace at \(path) has \(freeMB) MB free; need at least \(requiredMB) MB before accepting a job"
        }
    }
}
