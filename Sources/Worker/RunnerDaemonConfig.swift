import Foundation

/// Single source of truth for runner-daemon configuration that previously
/// lived in scattered `runnerEnvironmentBool` / `runnerEnvironmentInt`
/// reads across `RunnerDaemon`, `RunnerNetworkResilience`, and others.
///
/// Build once in `WorkerCommand.run()` via
/// `RunnerDaemonConfig.loadFromEnvironment()` and thread the result into
/// `Reporter`, `WorkerDaemon`, and the `RunnerRetryPolicy` factories.
/// Components stop reading the environment on their own — failure to
/// parse an env var fails fast at startup instead of silently degrading
/// later, and tests can construct a `RunnerDaemonConfig` directly
/// rather than mutating process env.
struct RunnerDaemonConfig: Sendable, Equatable {
    let capabilityDiscoveryEnabled: Bool
    let testSetupCacheDir: String?
    /// Root directory for job workspaces and per-job scratch copies. Defaults
    /// to the system temp directory (the historical behaviour). Override via
    /// `RUNNER_WORK_DIR`.
    ///
    /// It exists because the default is not always usable: a container that
    /// mounts `/tmp` as `tmpfs ... noexec` — which is a common hardening
    /// default, and is what the production runner does — can write a compiled
    /// binary there but never `exec` it. Interpreted languages do not care, so
    /// the setting only starts to matter once a language compiles something
    /// (C++), at which point every job dies with `Permission denied` at the
    /// `exec` line. Point this at a writable, exec-capable path to fix it.
    let workDir: String?
    let networkRetryEnabled: Bool
    let retryBaseDelayMs: Int
    let retryMaxDelayMs: Int
    let heartbeatRetryMaxAttempts: Int
    let resultUploadRetryMaxAttempts: Int
    let downloadRetryMaxAttempts: Int
    /// Minimum free space (megabytes) on the workspace filesystem before a
    /// job is allowed to stage. Jobs that don't clear this bar are
    /// rejected with a clear error instead of failing partway through with
    /// a cryptic ENOSPC. Override via `RUNNER_MIN_FREE_DISK_MB`; set to 0
    /// to disable the precheck.
    let minFreeDiskMB: Int
    /// Time limit (seconds) for the optional pre-test `make` step. The step
    /// runs after the student submission is merged into the workspace, so it
    /// must be bounded like any other student-influenced subprocess (#1107).
    /// Override via `RUNNER_MAKE_TIMEOUT_SECONDS`.
    let makeTimeoutSeconds: Int

    /// Built-in defaults — match the historical fallback values that
    /// `runnerEnvironmentBool` / `runnerEnvironmentInt` used when no
    /// env var was set.  Used by tests that don't care about env vars.
    static let defaults = RunnerDaemonConfig(
        capabilityDiscoveryEnabled: true,
        testSetupCacheDir: nil,
        workDir: nil,
        networkRetryEnabled: true,
        retryBaseDelayMs: 1000,
        retryMaxDelayMs: 30_000,
        heartbeatRetryMaxAttempts: 4,
        resultUploadRetryMaxAttempts: 8,
        downloadRetryMaxAttempts: 6,
        minFreeDiskMB: 128,
        makeTimeoutSeconds: 120
    )

    /// Reads every runner-config env var once.  Falls back to the
    /// historical defaults for any var that isn't set.
    static func loadFromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> RunnerDaemonConfig {
        RunnerDaemonConfig(
            capabilityDiscoveryEnabled: parseBool(
                env["RUNNER_CAPABILITY_DISCOVERY_ENABLED"], default: defaults.capabilityDiscoveryEnabled),
            testSetupCacheDir: env["RUNNER_TEST_SETUP_CACHE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty,
            workDir: env["RUNNER_WORK_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            networkRetryEnabled: parseBool(env["RUNNER_NETWORK_RETRY_ENABLED"], default: defaults.networkRetryEnabled),
            retryBaseDelayMs: parseInt(env["RUNNER_RETRY_BASE_DELAY_MS"], default: defaults.retryBaseDelayMs),
            retryMaxDelayMs: parseInt(env["RUNNER_RETRY_MAX_DELAY_MS"], default: defaults.retryMaxDelayMs),
            heartbeatRetryMaxAttempts: parseInt(
                env["RUNNER_HEARTBEAT_RETRY_MAX_ATTEMPTS"], default: defaults.heartbeatRetryMaxAttempts),
            resultUploadRetryMaxAttempts: parseInt(
                env["RUNNER_RESULT_UPLOAD_RETRY_MAX_ATTEMPTS"], default: defaults.resultUploadRetryMaxAttempts),
            downloadRetryMaxAttempts: parseInt(
                env["RUNNER_DOWNLOAD_RETRY_MAX_ATTEMPTS"], default: defaults.downloadRetryMaxAttempts),
            minFreeDiskMB: parseInt(env["RUNNER_MIN_FREE_DISK_MB"], default: defaults.minFreeDiskMB),
            makeTimeoutSeconds: parseInt(
                env["RUNNER_MAKE_TIMEOUT_SECONDS"], default: defaults.makeTimeoutSeconds)
        )
    }

    /// The resolved root for job workspaces and scratch copies.
    ///
    /// One accessor so the capability probe and the grading path cannot pick
    /// different directories — a probe that verified `exec` somewhere other
    /// than where jobs actually run would be worth nothing.
    var workRoot: URL {
        workDir.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
    }
}

// MARK: - Parsing helpers (file-private)

private func parseBool(_ raw: String?, default defaultValue: Bool) -> Bool {
    guard
        let trimmed = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
        !trimmed.isEmpty
    else { return defaultValue }

    switch trimmed {
    case "1", "true", "yes", "on": return true
    case "0", "false", "no", "off": return false
    default: return defaultValue
    }
}

private func parseInt(_ raw: String?, default defaultValue: Int) -> Int {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
        let value = Int(trimmed)
    else { return defaultValue }
    return value
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
