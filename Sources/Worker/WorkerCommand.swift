// Worker/WorkerCommand.swift
//
// The chickadee-runner CLI entry point (`@main`) plus worker-secret
// resolution (CLI flag → env var → .worker-secret file fallbacks). The CLI
// flag is deprecated; see `workerSecretFlagUse(flagSet:sandboxed:)`.
// Split from RunnerDaemon.swift (June 2026 audit); the WorkerDaemon
// actor itself stays in RunnerDaemon.swift.

import ArgumentParser
import CProcessHardening
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

    @Option(
        name: .long,
        help:
            "With --sandbox, the most processes and threads one test script may start at once"
    )
    var jobProcessLimit: Int = SandboxedScriptRunner.defaultProcessLimit

    @Option(
        name: .long,
        help:
            "With --sandbox on Linux, the megabytes one test script may write in its working directory; the writes are discarded when it ends"
    )
    var jobDiskLimit: Int = SandboxedScriptRunner.defaultDiskLimitMegabytes

    @Option(
        name: .long,
        help:
            "With --sandbox on Linux, the megabytes of memory one test script may use, its files included; needs the job cgroups that runner-entrypoint.sh delegates"
    )
    var jobMemoryLimit: Int = JobCgroups.defaultMemoryLimitMegabytes

    @Option(
        name: .long,
        help:
            "Deprecated, and refused with --sandbox: test scripts can read it. Set the RUNNER_SHARED_SECRET env var instead"
    )
    var workerSecret: String?

    @Option(
        name: .long,
        help:
            "Directory used for the runner test-setup cache (default: /tmp/chickadee-runner-cache; env: RUNNER_TEST_SETUP_CACHE_DIR)"
    )
    var testSetupCacheDir: String?

    /// Reports why the runner cannot start and returns the exit code to throw.
    ///
    /// One helper for both startup refusals so the message and the failing
    /// exit cannot come apart: a refusal that exits without saying why leaves
    /// an operator with a runner that silently never polls.
    static func startupFailure(_ message: String) -> ExitCode {
        writeToStandardError(message)
        return .failure
    }

    mutating func run() async throws {
        // A test script runs as the runner's user. Without this it can read
        // RUNNER_SHARED_SECRET from /proc/<runner pid>/environ and sign worker
        // API calls, for example to report its own result. `--sandbox` blocks
        // the read too, but only where the host allows user namespaces.
        let inspectionRefused = chickadee_refuse_process_inspection() == 0

        switch Self.workerSecretFlagUse(flagSet: workerSecret != nil, sandboxed: sandbox) {
        case .notUsed:
            break
        case .deprecated(let warning):
            writeToStandardError(warning)
        case .refused(let reason):
            throw Self.startupFailure(reason)
        }

        guard let baseURL = URL(string: apiBaseURL) else {
            throw Self.startupFailure("Error: invalid --api-base-url '\(apiBaseURL)'\n")
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

        let sandboxCheck = try await checkSandbox(workRoot: workRoot)

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
            throw Self.startupFailure(
                "Error: missing runner secret. Set RUNNER_SHARED_SECRET.\n")
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
        let (runner, sandboxLabel) = Self.scriptRunner(
            sandboxed: sandbox, processLimit: jobProcessLimit, diskLimitMegabytes: jobDiskLimit,
            memoryLimitMegabytes: jobMemoryLimit, cgroups: sandboxCheck.cgroups)

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
                "process_inspection": inspectionRefused ? "refused" : "allowed",
                "test_setup_cache_dir": cacheDirPath,
            ].merging(jobLimitLogFields(sandboxCheck)) { first, _ in first })
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
        let terminateSource = Self.drainOnTerminate(daemon)
        defer { terminateSource.cancel() }
        try await daemon.run()
    }

    /// Makes SIGTERM drain the runner rather than stop it (`WorkerDaemon.drain`).
    /// `docker stop`, `docker compose up` on a new image and a host shutdown
    /// all send SIGTERM, then SIGKILL after the container's
    /// `stop_grace_period`. The runner is the container's first process, and
    /// the kernel delivers no signal to that process unless it handles the
    /// signal, so before this the runner ignored SIGTERM and was always
    /// killed, with its running jobs, when the grace period ended.
    static func drainOnTerminate(_ daemon: WorkerDaemon) -> any DispatchSourceSignal {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        source.setEventHandler { Task { await daemon.drain() } }
        source.resume()
        return source
    }

    /// What the startup check found about the sandbox's limits.
    struct SandboxCheck {
        /// Whether the kernel applies `--job-process-limit`.
        let processLimitEnforced: Bool
        /// The job cgroups, or `nil` when the runner has none.
        let cgroups: JobCgroups?
        /// `enabled`, or why the job cgroups are not used, for the startup log.
        let cgroupsStatus: String
    }

    /// Checks the sandbox at startup: whether the kernel applies
    /// `--job-process-limit`, and whether each job can have its own cgroup.
    ///
    /// It refuses to start with `--sandbox` on a host that cannot sandbox. The
    /// alternative is a runner that claims jobs and fails every one of them.
    /// The process limit isolates the jobs from each other only when the
    /// kernel applies it and the container can hold every job at its limit,
    /// and the memory limit only when the job cgroups work. None of them stops
    /// grading, so each warns rather than refuses.
    func checkSandbox(workRoot: URL) async throws -> SandboxCheck {
        guard jobProcessLimit >= 1 else {
            throw Self.startupFailure("Error: --job-process-limit must be at least 1\n")
        }
        guard jobDiskLimit >= 1 else {
            throw Self.startupFailure("Error: --job-disk-limit must be at least 1\n")
        }
        guard jobMemoryLimit >= 1 else {
            throw Self.startupFailure("Error: --job-memory-limit must be at least 1\n")
        }
        guard sandbox else {
            return SandboxCheck(processLimitEnforced: false, cgroups: nil, cgroupsStatus: "not sandboxed")
        }
        if let reason = await SandboxedScriptRunner.probe(workDir: workRoot) {
            throw Self.startupFailure(
                "Error: --sandbox is set, but this host cannot start the sandbox: \(reason)\n"
                    + SandboxedScriptRunner.probeFailureAdvice + "\n")
        }
        let enforced = await SandboxedScriptRunner.processLimitIsEnforced(workDir: workRoot)
        if !enforced {
            writeToStandardError(
                "Warning: --job-process-limit is not enforced on this host. The kernel does not "
                    + "apply it when the runner runs as root, so one job can fork until the "
                    + "container's processes are used up. Run the runner as a non-root user.\n")
        }
        if let containerLimit = JobProcessBudget.readContainerLimit(),
            let warning = JobProcessBudget(
                containerLimit: containerLimit, maxJobs: maxJobs, processLimit: jobProcessLimit
            ).warning
        {
            writeToStandardError(warning)
        }
        let (cgroups, cgroupsStatus) = await Self.checkJobCgroups(workRoot: workRoot)
        if cgroups != nil, let containerLimit = JobMemoryBudget.readContainerLimit(),
            let warning = JobMemoryBudget(
                containerLimitBytes: containerLimit, maxJobs: maxJobs, memoryLimitMegabytes: jobMemoryLimit
            ).warning
        {
            writeToStandardError(warning)
        }
        return SandboxCheck(processLimitEnforced: enforced, cgroups: cgroups, cgroupsStatus: cgroupsStatus)
    }

    /// The job limits as the startup log reports them: each limit, or `none`
    /// where it does not apply.
    func jobLimitLogFields(_ check: SandboxCheck) -> [String: Any] {
        [
            "job_process_limit": sandbox ? "\(jobProcessLimit)" : "none",
            "job_process_limit_enforced": check.processLimitEnforced,
            "job_disk_limit_mb": sandbox ? "\(jobDiskLimit)" : "none",
            "job_cgroups": check.cgroupsStatus,
            "job_memory_limit_mb": check.cgroups != nil ? "\(jobMemoryLimit)" : "none",
        ]
    }

    /// Finds the job cgroups and checks that a sandboxed command runs in one.
    /// Returns the cgroups, or `nil` with the reason after a warning.
    static func checkJobCgroups(workRoot: URL) async -> (JobCgroups?, String) {
        let reason: String
        switch JobCgroups.discover() {
        case .available(let cgroups):
            guard let failure = await SandboxedScriptRunner.jobCgroupProbe(cgroups: cgroups, workDir: workRoot)
            else { return (cgroups, "enabled") }
            reason = failure
        case .unavailable(let why):
            reason = why
        }
        writeToStandardError(
            "Warning: job cgroups are unavailable, so --job-memory-limit is not applied and one job "
                + "can use the memory of every job on this runner: \(reason). Start the runner "
                + "container through /app/runner-entrypoint.sh (see deploy/README.md).\n")
        return (nil, "unavailable: \(reason)")
    }

    /// The script runner `--sandbox` selects, with the label the startup log
    /// reports for it. One decision for both, so the log cannot describe a
    /// different runner from the one that grades.
    static func scriptRunner(
        sandboxed: Bool,
        processLimit: Int = SandboxedScriptRunner.defaultProcessLimit,
        diskLimitMegabytes: Int = SandboxedScriptRunner.defaultDiskLimitMegabytes,
        memoryLimitMegabytes: Int = JobCgroups.defaultMemoryLimitMegabytes,
        cgroups: JobCgroups? = nil
    ) -> (runner: any ScriptRunner, label: String) {
        sandboxed
            ? (
                SandboxedScriptRunner(
                    processLimit: processLimit, diskLimitMegabytes: diskLimitMegabytes,
                    memoryLimitMegabytes: memoryLimitMegabytes, cgroups: cgroups),
                "sandboxed"
            )
            : (UnsandboxedScriptRunner(), "unsandboxed")
    }

    /// What the runner does when `--worker-secret` is set.
    enum WorkerSecretFlagUse: Equatable {
        case notUsed
        case deprecated(warning: String)
        case refused(reason: String)
    }

    /// `--worker-secret` puts the secret in the runner's command line, and any
    /// process of the same user can read `/proc/<pid>/cmdline`, whatever the
    /// runner's dumpable flag. That includes every test script, also inside
    /// the sandbox, which has no PID namespace. With the secret, a script can
    /// sign worker API calls, for example to report its own result.
    ///
    /// With `--sandbox`, the operator asked for isolation that the flag
    /// defeats, so the runner refuses to start. Without it, the flag only
    /// warns: a patch may not remove it (docs/release-process.md), so it is
    /// removed at the next minor release.
    static func workerSecretFlagUse(flagSet: Bool, sandboxed: Bool) -> WorkerSecretFlagUse {
        guard flagSet else { return .notUsed }
        let why =
            "--worker-secret puts the secret in the runner's command line, "
            + "where every test script can read it. Set RUNNER_SHARED_SECRET instead.\n"
        if sandboxed {
            return .refused(reason: "Error: --worker-secret cannot be used with --sandbox. " + why)
        }
        return .deprecated(
            warning: "Warning: --worker-secret is deprecated and will be removed in the next minor release. " + why)
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
