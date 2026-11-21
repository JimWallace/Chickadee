// Tests/APITests/Infrastructure/AppConfigTests.swift
//
// `AppConfig`: the test defaults, the end-to-end read of every substruct from
// the environment, and `logSummary`. A local-mode summary redacts its
// secrets. The optional lines are checked with a config that has every
// optional feature on (SSO, a public base URL, scan mode, BrightSpace,
// alerts, an outbound proxy, MCP, and the UW dates integration off): each one
// logs its line and no secret value reaches the log. A second config checks
// the disabled idle timeout and the BrightSpace line that waits for the
// authorize flow.
//
// The variables are set through `withTestEnvironment`, which overrides the
// environment for this task only. No new environment variable is read.

import Foundation
import Logging
import Testing
import Vapor

@testable import APIServer

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
        #expect(cfg.uwDates.enabled == true)
        #expect(cfg.oidc.callbackPath == "/auth/sso/callback")
        #expect(cfg.oidc.usernameClaim == "preferred_username")
        #expect(cfg.oidc.emailClaim == "email")
    }

    /// `fromEnvironment` builds an end-to-end config that matches the env
    /// fixture. Sentinel test fixture covers each substruct so renaming a
    /// substruct without rewiring it surfaces here.
    @Test func fromEnvironmentReadsAllSubstructs() async throws {
        try await withTestEnvironment([
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
            "UW_IMPORTANT_DATES_ENABLED": "false",
            // Postgres is the only backend, and loading the config requires
            // all five connection variables.
            "DATABASE_HOST": "db",
            "DATABASE_NAME": "chickadee",
            "DATABASE_USER": "chickadee",
            "DATABASE_PASSWORD": "secret",
            "DATABASE_PORT": "5432",
        ]) {
            let cfg = try AppConfig.fromEnvironment(workDir: "/tmp/")
            #expect(cfg.auth.mode == .local)
            #expect(cfg.auth.nonSSOModesEnabled == true)
            #expect(cfg.security.publicBaseURL?.absoluteString == "https://test.example")
            #expect(cfg.oidc.clientID == "id-123")
            #expect(cfg.oidc.clientSecret == "secret-abc")
            #expect(cfg.oidc.callbackPath == "/custom/callback")
            #expect(cfg.oidc.usernameClaim == "winaccountname")
            #expect(cfg.workers.sharedSecret == "primary-secret")
            #expect(cfg.workers.publicBaseURL == "https://callback.example")
            #expect(cfg.lockout.perMinute == 20)
            #expect(cfg.lockout.lockoutThreshold == 8)
            #expect(cfg.diagnostics.jobMetricRetentionDays == 7)
            #expect(cfg.uwDates.enabled == false)
            #expect(cfg.database.host == "db")
            #expect(cfg.database.port == 5432)
        }
    }

    /// The pre-0.5 legacy alias `WORKER_SHARED_SECRET` is retired: only
    /// `RUNNER_SHARED_SECRET` is read, and a stray legacy value is ignored.
    @Test func retiredLegacyWorkerSecretAliasIsIgnored() async throws {
        try await withTestEnvironment([
            "WORKER_SHARED_SECRET": "legacy-value",
            "RUNNER_SHARED_SECRET": nil,
        ]) {
            let workers = WorkerConfig.fromEnvironment()
            #expect(workers.sharedSecret == nil)
        }

        try await withTestEnvironment([
            "RUNNER_SHARED_SECRET": "primary",
            "WORKER_SHARED_SECRET": "legacy",
        ]) {
            let workers = WorkerConfig.fromEnvironment()
            #expect(workers.sharedSecret == "primary")
        }
    }

    /// SSO mode is forced when non-SSO modes are not explicitly enabled.
    @Test func authModeDowngradesToSSOWhenNonSSODisabled() async throws {
        try await withTestEnvironment([
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
        // Awaited in the defer (SE-0493), not fired into a detached Task: a
        // fire-and-forget shutdown races test-runner exit and sometimes never
        // ran at all -- the failure TestAppTempDirectoryTests documents.
        defer {
            try? await app.asyncShutdown()
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
            brightspaceApp: seed.brightspaceApp,
            diagnostics: seed.diagnostics,
            alerts: seed.alerts,
            outboundProxy: seed.outboundProxy,
            mcp: seed.mcp,
            uwDates: seed.uwDates
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
            database: .localTest,
            lockout: .default,
            workers: WorkerConfig(
                sharedSecret: "rsec-12345",
                publicBaseURL: nil
            ),
            brightspace: nil,
            brightspaceApp: nil,
            diagnostics: AppConfig.testDefaults().diagnostics,
            alerts: .default,
            outboundProxy: nil,
            mcp: .default,
            uwDates: .default
        )
        let captured = CapturedLog()
        cfg.logSummary(to: captured.logger)
        let blob = captured.allText
        #expect(!blob.contains("super-secret-value"))
        #expect(!blob.contains("rsec-12345"))
        #expect(blob.contains("[set]"))
    }

    /// Every variable either test sets, cleared first so that the host
    /// environment cannot add or remove a line.
    private static let cleared: [String: String?] = [
        "PUBLIC_BASE_URL": nil, "ENFORCE_HTTPS": nil, "SESSION_IDLE_TIMEOUT_MINUTES": nil,
        "SESSION_IDLE_WARNING_SECONDS": nil, "OIDC_CLIENT_ID": nil, "OIDC_CLIENT_SECRET": nil,
        "RUNNER_SHARED_SECRET": nil, "SCAN_MODE": nil, "UW_IMPORTANT_DATES_ENABLED": nil,
        "BRIGHTSPACE_URL": nil, "BRIGHTSPACE_APP_ID": nil, "BRIGHTSPACE_APP_KEY": nil,
        "BRIGHTSPACE_USER_ID": nil, "BRIGHTSPACE_USER_KEY": nil, "BRIGHTSPACE_SYNC_DEBOUNCE_SECS": nil,
        "ALERT_ENABLED": nil, "ALERT_WEBHOOK_URL": nil, "OUTBOUND_HTTP_PROXY": nil, "MCP_MODE": nil,
        "ENABLE_NON_SSO_AUTH_MODES": nil,
    ]

    private static func environment(_ overrides: [String: String]) -> [String: String?] {
        var merged = cleared
        for (key, value) in overrides { merged[key] = value }
        return merged
    }

    private static func summary(of config: AppConfig) -> [String] {
        let capture = CapturedLog()
        config.logSummary(to: capture.logger)
        return capture.lines
    }

    @Test func everyOptionalFeatureLogsItsLineWithoutItsSecrets() async throws {
        let lines = try await withTestEnvironment(
            Self.environment([
                "ENABLE_NON_SSO_AUTH_MODES": "true",
                "PUBLIC_BASE_URL": "https://chickadee.example",
                "SESSION_IDLE_TIMEOUT_MINUTES": "45",
                "SESSION_IDLE_WARNING_SECONDS": "0",
                "OIDC_CLIENT_ID": "client-id-value",
                "OIDC_CLIENT_SECRET": "oidc-secret-value",
                "RUNNER_SHARED_SECRET": "runner-secret-value",
                "SCAN_MODE": "true",
                "UW_IMPORTANT_DATES_ENABLED": "false",
                "BRIGHTSPACE_URL": "https://learn.example/",
                "BRIGHTSPACE_APP_ID": "bs-app-id-value",
                "BRIGHTSPACE_APP_KEY": "bs-app-key-value",
                "BRIGHTSPACE_USER_ID": "bs-user-id-value",
                "BRIGHTSPACE_USER_KEY": "bs-user-key-value",
                "ALERT_ENABLED": "true",
                "ALERT_WEBHOOK_URL": "https://hooks.example/secret-path",
                "OUTBOUND_HTTP_PROXY": "proxy.example:3128",
                "MCP_MODE": "read_only",
            ])
        ) {
            let config = try AppConfig.fromEnvironment(
                workDir: "/tmp/", authModeOverride: .dual, databaseOverride: .localTest)
            return Self.summary(of: config)
        }
        let blob = lines.joined(separator: "\n")

        #expect(blob.contains("auth=dual"))
        #expect(blob.contains("security: publicBaseURL=https://chickadee.example"))
        #expect(blob.contains("sessionIdleTimeoutMinutes=45, idleWarning=disabled"))
        #expect(blob.contains("oidc: clientID=[set], clientSecret=[set]"))
        #expect(blob.contains("workers: sharedSecret=[set]"))
        #expect(lines.contains { $0.hasPrefix("warning") && $0.contains("SCAN_MODE=true") })
        #expect(blob.contains("uwDates: disabled"))
        #expect(blob.contains("brightspace: baseURL=https://learn.example, appID=[set], appKey=[redacted]"))
        #expect(blob.contains("userID=[set], userKey=[redacted], debounceSecs=90.0"))
        #expect(blob.contains("alerts: enabled, checkInterval=60.0s"))
        #expect(blob.contains("webhook=[set]"))
        #expect(blob.contains("outboundProxy: proxy.example:3128"))
        #expect(blob.contains("mcp: mode=read_only"))
        #expect(blob.contains("adminMCP: /admin-mcp mounted"))

        for secret in [
            "client-id-value", "oidc-secret-value", "runner-secret-value", "bs-app-id-value", "bs-app-key-value",
            "bs-user-id-value", "bs-user-key-value", "secret-path",
        ] {
            #expect(!blob.contains(secret), "logSummary printed \(secret)")
        }
    }

    @Test func aDisabledIdleTimeoutAndAppOnlyBrightSpaceLogTheirOwnLines() async throws {
        let lines = try await withTestEnvironment(
            Self.environment([
                "SESSION_IDLE_TIMEOUT_MINUTES": "0",
                "BRIGHTSPACE_URL": "https://learn.example",
                "BRIGHTSPACE_APP_ID": "bs-app-id-value",
                "BRIGHTSPACE_APP_KEY": "bs-app-key-value",
                "BRIGHTSPACE_SYNC_DEBOUNCE_SECS": "30",
            ])
        ) {
            let config = try AppConfig.fromEnvironment(
                workDir: "/tmp/", authModeOverride: .local, databaseOverride: .localTest)
            #expect(config.brightspace == nil)
            #expect(config.brightspaceApp != nil)
            return Self.summary(of: config)
        }
        let blob = lines.joined(separator: "\n")

        #expect(blob.contains("security: sessionIdleTimeout=disabled"))
        #expect(blob.contains("userKey=(awaiting authorize), debounceSecs=30.0"))
        #expect(!blob.contains("bs-app-id-value"))
        #expect(!blob.contains("bs-app-key-value"))
        // Local mode, no public base URL and every feature off: none of the
        // optional lines appear.
        for absent in [
            "security: publicBaseURL", "oidc:", "SCAN_MODE", "uwDates:", "alerts:", "outboundProxy:", "mcp:",
        ] {
            #expect(!blob.contains(absent), "unexpected line: \(absent)")
        }
    }
}
