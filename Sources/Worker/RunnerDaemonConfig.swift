import Foundation

/// Single source of truth for runner-daemon configuration that previously
/// lived in scattered `runnerEnvironmentBool` / `runnerEnvironmentInt`
/// reads across `RunnerDaemon`, `RunnerNetworkResilience`, and others.
///
/// Build once in `WorkerCommand.run()` via
/// `RunnerDaemonConfig.loadFromEnvironment()` and thread the result into
/// `Reporter`, `WorkerDaemon`, and the `RunnerRetryPolicy` factories.
/// Components stop reading the environment on their own, and tests can
/// construct a `RunnerDaemonConfig` directly rather than mutating process env.
///
/// An unparseable value falls back to the default and is REPORTED
/// (`runner_config_parse_failed`) rather than fixing itself in silence. This
/// comment used to claim the parse "fails fast at startup"; it never did, and
/// the tests pinned the fallback — so an operator's typo produced a runner
/// quietly running on defaults with nothing anywhere saying so.
struct RunnerDaemonConfig: Sendable, Equatable {
    let capabilityDiscoveryEnabled: Bool
    let testSetupCacheDir: String?
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
                "RUNNER_CAPABILITY_DISCOVERY_ENABLED", env["RUNNER_CAPABILITY_DISCOVERY_ENABLED"],
                default: defaults.capabilityDiscoveryEnabled),
            testSetupCacheDir: env["RUNNER_TEST_SETUP_CACHE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty,
            networkRetryEnabled: parseBool(
                "RUNNER_NETWORK_RETRY_ENABLED", env["RUNNER_NETWORK_RETRY_ENABLED"],
                default: defaults.networkRetryEnabled),
            retryBaseDelayMs: clampDelayMs(
                "RUNNER_RETRY_BASE_DELAY_MS",
                parseInt(
                    "RUNNER_RETRY_BASE_DELAY_MS", env["RUNNER_RETRY_BASE_DELAY_MS"],
                    default: defaults.retryBaseDelayMs),
                default: defaults.retryBaseDelayMs),
            retryMaxDelayMs: clampDelayMs(
                "RUNNER_RETRY_MAX_DELAY_MS",
                parseInt(
                    "RUNNER_RETRY_MAX_DELAY_MS", env["RUNNER_RETRY_MAX_DELAY_MS"],
                    default: defaults.retryMaxDelayMs),
                default: defaults.retryMaxDelayMs),
            heartbeatRetryMaxAttempts: parseInt(
                "RUNNER_HEARTBEAT_RETRY_MAX_ATTEMPTS", env["RUNNER_HEARTBEAT_RETRY_MAX_ATTEMPTS"],
                default: defaults.heartbeatRetryMaxAttempts),
            resultUploadRetryMaxAttempts: parseInt(
                "RUNNER_RESULT_UPLOAD_RETRY_MAX_ATTEMPTS",
                env["RUNNER_RESULT_UPLOAD_RETRY_MAX_ATTEMPTS"],
                default: defaults.resultUploadRetryMaxAttempts),
            downloadRetryMaxAttempts: parseInt(
                "RUNNER_DOWNLOAD_RETRY_MAX_ATTEMPTS", env["RUNNER_DOWNLOAD_RETRY_MAX_ATTEMPTS"],
                default: defaults.downloadRetryMaxAttempts),
            minFreeDiskMB: parseInt(
                "RUNNER_MIN_FREE_DISK_MB", env["RUNNER_MIN_FREE_DISK_MB"],
                default: defaults.minFreeDiskMB),
            makeTimeoutSeconds: parseInt(
                "RUNNER_MAKE_TIMEOUT_SECONDS", env["RUNNER_MAKE_TIMEOUT_SECONDS"],
                default: defaults.makeTimeoutSeconds)
        )
    }

}

// MARK: - Parsing helpers (file-private)

/// Reports an env var that was SET but could not be parsed.
///
/// The silent fallback is what made this worth a log line. An operator moving a
/// runner off a small disk who writes `RUNNER_MIN_FREE_DISK_MB=2GB` got the
/// 128 MB default and a runner that kept claiming jobs onto a nearly-full
/// volume — the ENOSPC-partway-through failure that setting exists to prevent,
/// reintroduced by the setting meant to fix it. Absent stays silent; only
/// present-and-unparseable is reported.
private func reportUnparseable(_ key: String, _ raw: String, _ fallback: String) {
    writeStructuredRunnerLog(
        event: "runner_config_parse_failed",
        fields: [
            "variable": key,
            "raw_value": raw,
            "using_default": fallback,
        ])
}

private func parseBool(_ key: String, _ raw: String?, default defaultValue: Bool) -> Bool {
    guard
        let trimmed = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
        !trimmed.isEmpty
    else { return defaultValue }

    switch trimmed {
    case "1", "true", "yes", "on": return true
    case "0", "false", "no", "off": return false
    default:
        reportUnparseable(key, trimmed, "\(defaultValue)")
        return defaultValue
    }
}

private func parseInt(_ key: String, _ raw: String?, default defaultValue: Int) -> Int {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return defaultValue }
    guard let value = Int(trimmed) else {
        reportUnparseable(key, trimmed, "\(defaultValue)")
        return defaultValue
    }
    return value
}

/// A non-negative duration in milliseconds, with a ceiling.
///
/// The retry delays feed `baseDelayMs * 2^attempt`, an unchecked multiply that
/// TRAPS the runner on its first retry for a large enough base; and a negative
/// max yields a negative `Duration`, which `Task.sleep` returns from
/// immediately — turning the retry loop into a spin against the API server,
/// unbounded for the poll stage. Both are operator-set values, so clamping at
/// the boundary is cheaper than defending every arithmetic site.
private func clampDelayMs(_ key: String, _ value: Int, default defaultValue: Int) -> Int {
    let ceiling = 3_600_000  // one hour; nothing legitimate waits longer
    guard value >= 0, value <= ceiling else {
        reportUnparseable(key, "\(value)", "\(defaultValue)")
        return defaultValue
    }
    return value
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
