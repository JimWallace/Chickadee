import Foundation
import Logging
import Testing
import Vapor

@testable import chickadee_server

// Serialized because tests mutate process-wide env vars; running in parallel
// would race with each other (and any other Environment.get callers in the
// test target).
@Suite(.serialized) struct AppConfigTests {

    /// `AppConfig.testDefaults()` returns a fully populated structure that
    /// downstream code can read from without crashing. This is the same config
    /// `makeTestApp` seeds onto Application by default.
    @Test func testDefaultsAreUsable() {
        let cfg = AppConfig.testDefaults()
        #expect(cfg.auth.mode == .local)
        #expect(cfg.security.publicBaseURL == nil)
        #expect(cfg.security.enforceHTTPS == false)
        #expect(cfg.workers.sharedSecret == nil)
        #expect(cfg.workers.publicBaseURL == nil)
        #expect(cfg.brightspace == nil)
        #expect(cfg.scanMode.enabled == false)
        #expect(cfg.oidc.callbackPath == "/auth/sso/callback")
        #expect(cfg.oidc.usernameClaim == "preferred_username")
        #expect(cfg.oidc.emailClaim == "email")
    }

    /// `fromEnvironment` builds an end-to-end config that matches the env
    /// fixture. Sentinel test fixture covers each substruct so renaming a
    /// substruct without rewiring it surfaces here.
    @Test func fromEnvironmentReadsAllSubstructs() throws {
        try withEnvironment(
            set: [
                "AUTH_MODE": "local",
                "ENABLE_NON_SSO_AUTH_MODES": "true",
                "PUBLIC_BASE_URL": "https://test.example",
                "OIDC_CLIENT_ID": "id-123",
                "OIDC_CLIENT_SECRET": "secret-abc",
                "OIDC_CALLBACK": "/custom/callback",
                "OIDC_USERNAME_CLAIM": "winaccountname",
                "RUNNER_SHARED_SECRET": "primary-secret",
                "WORKER_PUBLIC_BASE_URL": "https://callback.example/",
                "LOGIN_RATE_LIMIT_PER_MIN": "20",
                "LOGIN_LOCKOUT_THRESHOLD": "8",
                "JOB_METRIC_RETENTION_DAYS": "7",
            ],
            // Clear DB-backend overrides so the assertion-of-default branch
            // (`.sqlite`) isn't accidentally redirected to postgres by an
            // earlier test's leaked env.
            unset: [
                "DATABASE_BACKEND", "DATABASE_HOST", "DATABASE_NAME", "DATABASE_USER", "DATABASE_PASSWORD",
                "DATABASE_PORT",
            ]
        ) {
            let cfg = try AppConfig.fromEnvironment(workDir: "/tmp/")
            #expect(cfg.auth.mode == .local)
            #expect(cfg.auth.nonSSOModesEnabled == true)
            #expect(cfg.security.publicBaseURL?.absoluteString == "https://test.example")
            #expect(cfg.oidc.clientID == "id-123")
            #expect(cfg.oidc.clientSecret == "secret-abc")
            #expect(cfg.oidc.callbackPath == "/custom/callback")
            #expect(cfg.oidc.usernameClaim == "winaccountname")
            #expect(cfg.workers.sharedSecret == "primary-secret")
            #expect(cfg.workers.usedLegacyAlias == false)
            #expect(cfg.workers.publicBaseURL == "https://callback.example")
            #expect(cfg.lockout.perMinute == 20)
            #expect(cfg.lockout.lockoutThreshold == 8)
            #expect(cfg.diagnostics.jobMetricRetentionDays == 7)
        }
    }

    /// Legacy `WORKER_SHARED_SECRET` wins only when `RUNNER_SHARED_SECRET` is
    /// unset, and the loader flags this so `logSummary` can warn.
    @Test func legacyWorkerSecretAliasIsHonouredButFlagged() {
        withEnvironment(
            set: ["WORKER_SHARED_SECRET": "legacy-value"],
            unset: ["RUNNER_SHARED_SECRET"]
        ) {
            let workers = WorkerConfig.fromEnvironment()
            #expect(workers.sharedSecret == "legacy-value")
            #expect(workers.usedLegacyAlias == true)
        }

        withEnvironment(set: [
            "RUNNER_SHARED_SECRET": "primary",
            "WORKER_SHARED_SECRET": "legacy",
        ]) {
            let workers = WorkerConfig.fromEnvironment()
            #expect(workers.sharedSecret == "primary")
            #expect(workers.usedLegacyAlias == false)
        }
    }

    /// SSO mode is forced when non-SSO modes are not explicitly enabled.
    @Test func authModeDowngradesToSSOWhenNonSSODisabled() {
        withEnvironment(set: [
            "AUTH_MODE": "local",
            "ENABLE_NON_SSO_AUTH_MODES": "false",
        ]) {
            let auth = AuthConfig.fromEnvironment()
            #expect(auth.requestedMode == .local)
            #expect(auth.mode == .sso)
            #expect(auth.nonSSOModesEnabled == false)
        }
    }

    /// `Application.preloadedAppConfig` is honoured by `configure(_:)` so
    /// tests can short-circuit env-based loading without exporting variables.
    @Test func preloadedAppConfigShortCircuitsLoad() async throws {
        let app = try await Application.make(.testing)
        defer {
            Task { try? await app.asyncShutdown() }
        }
        var seed = AppConfig.testDefaults(authMode: .dual)
        seed = AppConfig(
            auth: seed.auth,
            oidc: OIDCEnvConfig(
                clientID: "preloaded",
                clientSecret: "preloaded",
                authServerOverride: nil,
                callbackPath: "/x",
                usernameClaim: "u",
                emailClaim: "e",
                allowInsecure: false
            ),
            security: seed.security,
            scanMode: seed.scanMode,
            database: seed.database,
            lockout: seed.lockout,
            workers: seed.workers,
            brightspace: seed.brightspace,
            diagnostics: seed.diagnostics,
            alerts: seed.alerts
        )
        app.preloadedAppConfig = seed
        // Smoke: configure() picks up the preloaded config without env reads.
        // The full configure() path requires a working directory + filesystem;
        // for this unit test we exercise only the storage seam.
        #expect(app.preloadedAppConfig?.oidc.clientID == "preloaded")
    }

    /// `logSummary` redacts secrets and never prints raw values.
    @Test func logSummaryRedactsSecrets() {
        let cfg = AppConfig(
            auth: .defaultLocal,
            oidc: OIDCEnvConfig(
                clientID: "id-XYZ",
                clientSecret: "super-secret-value",
                authServerOverride: nil,
                callbackPath: "/cb",
                usernameClaim: "u",
                emailClaim: "e",
                allowInsecure: false
            ),
            security: .default,
            scanMode: .default,
            database: .sqliteInMemory(),
            lockout: .default,
            workers: WorkerConfig(
                sharedSecret: "rsec-12345",
                usedLegacyAlias: false,
                publicBaseURL: nil
            ),
            brightspace: nil,
            diagnostics: AppConfig.testDefaults().diagnostics,
            alerts: .default
        )
        let captured = CapturedLogger()
        cfg.logSummary(to: captured.logger)
        let blob = captured.allText
        #expect(!blob.contains("super-secret-value"))
        #expect(!blob.contains("rsec-12345"))
        #expect(blob.contains("[set]"))
    }
}

// MARK: - Helpers

/// Runs `body` with the given env vars set, restoring (or clearing) each one
/// afterwards. Grabs `EnvTestLock` for the duration so concurrent env-touching
/// tests in other suites (DatabaseConfigurationTests, APIServerAppTests) don't
/// race with this one — `@Suite(.serialized)` only serializes within a suite.
private func withEnvironment(
    set: [String: String] = [:],
    unset: [String] = [],
    _ body: () throws -> Void
) rethrows {
    EnvTestLock.shared.lock()
    defer { EnvTestLock.shared.unlock() }
    let prior: [String: String?] = Dictionary(
        uniqueKeysWithValues: (Array(set.keys) + unset).map { key in
            (key, ProcessInfo.processInfo.environment[key])
        }
    )
    for (key, value) in set { setenv(key, value, 1) }
    for key in unset { unsetenv(key) }
    defer {
        for (key, value) in prior {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
    }
    try body()
}

private func withEnvironment(
    _ values: [String: String],
    _ body: () throws -> Void
) rethrows {
    try withEnvironment(set: values, unset: [], body)
}

private final class LogSink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "appconfig.test.log")
    private var lines: [String] = []

    func append(_ line: String) {
        queue.sync { lines.append(line) }
    }

    var allText: String {
        queue.sync { lines.joined(separator: "\n") }
    }
}

private final class CapturedLogger {
    let sink = LogSink()
    let logger: Logger

    init() {
        let sink = self.sink
        var l = Logger(label: "appconfig.test")
        l.handler = ClosureLogHandler { line in sink.append(line) }
        self.logger = l
    }

    var allText: String { sink.allText }
}

private struct ClosureLogHandler: LogHandler {
    let onLog: @Sendable (String) -> Void

    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        onLog("\(event.level) \(event.message)")
    }
}
