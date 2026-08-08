// Worker/WorkerCommand.swift
//
// The chickadee-runner CLI entry point (`@main`) plus worker-secret
// resolution (CLI flag → env var → .worker-secret file fallbacks).
// Split from RunnerDaemon.swift (June 2026 audit); the WorkerDaemon
// actor itself stays in RunnerDaemon.swift.

import ArgumentParser
import Core
import Foundation

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

        let cacheDirPath =
            testSetupCacheDir
            ?? config.testSetupCacheDir
            ?? TestSetupCache.defaultCacheRoot.path
        // The cache directory IS the runner's working directory: prepared test
        // setups, the per-job scratch copies made from them, and the job
        // workspaces all live under it. One directory, one existing setting —
        // moving it moves everything, which is what an operator does when the
        // default lands on a `noexec` mount and a compiled language cannot
        // execute the binary it just built there.
        //
        // The same root feeds the executable-output capability probe below, so
        // the probe cannot pass in a directory jobs never use.
        let workRoot = URL(fileURLWithPath: cacheDirPath, isDirectory: true)
        // Created up front because scratch copies land here directly, and
        // `copyItem` needs the parent to exist — the system temp directory this
        // replaced always did.
        try FileManager.default.createDirectory(
            at: workRoot, withIntermediateDirectories: true)

        let runnerProfile = await RunnerProfileDetector(
            discoveryEnabled: config.capabilityDiscoveryEnabled,
            workRoot: workRoot
        ).detect()
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

        let testSetupCache = TestSetupCache(
            cacheRoot: workRoot,
            scratchRoot: workRoot)

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
            config: config,
            workRoot: workRoot
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
    environment: [String: String],
    currentDirectory: String = FileManager.default.currentDirectoryPath
) -> String? {
    let cliSecret = cliWorkerSecret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !cliSecret.isEmpty { return cliSecret }

    let envSecret = (environment["RUNNER_SHARED_SECRET"] ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if !envSecret.isEmpty { return envSecret }

    for path in defaultWorkerSecretFilePaths(currentDirectory: currentDirectory) {
        if let fileSecret = readWorkerSecretFromFile(path: path) {
            return fileSecret
        }
    }

    return nil
}

// `currentDirectory` is injectable so tests can point at a scratch directory
// instead of mutating the process-global working directory with `chdir`.
func defaultWorkerSecretFilePaths(
    currentDirectory: String = FileManager.default.currentDirectoryPath
) -> [String] {
    var paths: [String] = []

    let cwd = currentDirectory
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
