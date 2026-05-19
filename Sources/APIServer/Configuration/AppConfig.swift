// APIServer/Configuration/AppConfig.swift
//
// Single typed snapshot of every environment-variable knob the server reads.
// Loaded once at startup by `AppConfig.fromEnvironment(...)` and stored on the
// `Application` so the rest of the codebase never reaches for `Environment.get`
// directly. Tests can preload an `AppConfig` via `Application.preloadedAppConfig`
// to bypass the env entirely.

import Foundation
import Logging
import Vapor

struct AppConfig: Sendable {
    let auth: AuthConfig
    let oidc: OIDCEnvConfig
    let security: AppSecurityConfiguration
    let scanMode: ScanModeConfiguration
    let database: DatabaseSettings
    let lockout: LoginRateLimitConfiguration
    let workers: WorkerConfig
    let brightspace: BrightSpaceSyncConfig?
    let diagnostics: DiagnosticsConfiguration
    let alerts: ServerHealthAlertConfiguration

    /// Loads the entire config tree from `Environment.get(...)`.
    ///
    /// - Parameters:
    ///   - workDir: process working directory; used as the source of truth for
    ///     the default SQLite path.
    ///   - authModeOverride: forces a specific AuthMode regardless of env.
    ///     Used by tests and CLI overrides.
    static func fromEnvironment(
        workDir: String,
        authModeOverride: AuthMode? = nil
    ) throws -> AppConfig {
        let auth = AuthConfig.fromEnvironment(override: authModeOverride)
        let security = AppSecurityConfiguration.fromEnvironment(authMode: auth.mode)
        let database = try DatabaseSettings.fromEnvironment(
            defaultSQLitePath: workDir + "chickadee.sqlite"
        )
        return AppConfig(
            auth: auth,
            oidc: OIDCEnvConfig.fromEnvironment(),
            security: security,
            scanMode: ScanModeConfiguration.fromEnvironment(),
            database: database,
            lockout: LoginRateLimitConfiguration.fromEnvironment(
                trustForwardedFor: security.trustForwardedProto
            ),
            workers: WorkerConfig.fromEnvironment(),
            brightspace: BrightSpaceSyncConfig.fromEnvironment(),
            diagnostics: DiagnosticsConfiguration.fromEnvironment(),
            alerts: ServerHealthAlertConfiguration.fromEnvironment()
        )
    }

    /// Emits a one-shot startup summary describing the loaded config. Secrets
    /// (OIDC client secret, runner secret, BrightSpace keys, DB password) are
    /// replaced with `[redacted]`. Use the grep guardrail in CI to keep this
    /// honest.
    func logSummary(to logger: Logger) {
        logger.info("AppConfig loaded — auth=\(auth.mode.rawValue), database=\(database.backend.rawValue)")
        if security.publicBaseURL != nil || security.enforceHTTPS {
            logger.info(
                "security: publicBaseURL=\(security.publicBaseURL?.absoluteString ?? "(unset)"), enforceHTTPS=\(security.enforceHTTPS), trustForwardedProto=\(security.trustForwardedProto), sessionCookieSecure=\(security.sessionCookieSecure)"
            )
        }
        let idleTimeout = security.sessionIdleTimeoutSeconds
        if idleTimeout > 0 {
            logger.info("security: sessionIdleTimeoutMinutes=\(Int(idleTimeout / 60))")
        } else {
            logger.info("security: sessionIdleTimeout=disabled")
        }
        if auth.mode != .local {
            logger.info(
                "oidc: clientID=\(redactPresence(oidc.clientID)), clientSecret=\(redactPresence(oidc.clientSecret)), callbackPath=\(oidc.callbackPath), usernameClaim=\(oidc.usernameClaim), emailClaim=\(oidc.emailClaim)"
            )
        }
        logger.info(
            "workers: sharedSecret=\(redactPresence(workers.sharedSecret)), publicBaseURL=\(workers.publicBaseURL ?? "(derived from request)")"
        )
        if workers.usedLegacyAlias {
            logger.warning(
                "WORKER_SHARED_SECRET is set but RUNNER_SHARED_SECRET is not — the legacy name is deprecated, switch to RUNNER_SHARED_SECRET."
            )
        }
        if scanMode.enabled {
            logger.warning("SCAN_MODE=true — destructive POST endpoints are returning 503.")
        }
        if let bs = brightspace {
            logger.info(
                "brightspace: baseURL=\(bs.baseURL), appID=\(redactPresence(bs.appID)), appKey=[redacted], userID=\(redactPresence(bs.userID)), userKey=[redacted], debounceSecs=\(bs.debounceSecs)"
            )
        }
        logger.info(
            "diagnostics: enabled=\(diagnostics.enabled), verbose=\(diagnostics.verboseRequestTiming), retention(jobs/snapshots)=\(diagnostics.jobMetricRetentionDays)d/\(diagnostics.runnerSnapshotRetentionDays)d"
        )
        if alerts.enabled {
            logger.info(
                "alerts: enabled, checkInterval=\(alerts.checkIntervalSeconds)s, cooldown=\(alerts.cooldownSeconds)s, webhook=\(redactPresence(alerts.webhookURLFromEnvironment))"
            )
        }
    }
}

/// Renders a secret-bearing value as either "[set]" or "(unset)". Never prints
/// the raw value. Used by `logSummary` for credential-shaped fields.
private func redactPresence(_ value: String?) -> String {
    (value?.isEmpty == false) ? "[set]" : "(unset)"
}

// MARK: - Application storage

struct AppConfigKey: StorageKey {
    typealias Value = AppConfig
}

/// Tests can set this before `configure(_:)` runs to bypass `Environment.get`
/// entirely. `configure(_:)` checks this storage key first; when present, the
/// preloaded config is used verbatim.
struct PreloadedAppConfigKey: StorageKey {
    typealias Value = AppConfig
}

extension Application {
    var appConfig: AppConfig {
        get {
            if let existing = storage[AppConfigKey.self] { return existing }
            // Lazy fallback for tests + tooling that bypass `configure(_:)`:
            // build once from the process environment so env-set OIDC paths,
            // SSO allowlists, etc. still flow through. Falls back to
            // `testDefaults()` if env-parsing fails (e.g. malformed DATABASE
            // settings — irrelevant for tests that override the DB
            // separately via `configureTestDatabase`).
            let workDir = DirectoryConfiguration.detect().workingDirectory
            let built = (try? AppConfig.fromEnvironment(workDir: workDir)) ?? AppConfig.testDefaults()
            storage[AppConfigKey.self] = built
            return built
        }
        set { storage[AppConfigKey.self] = newValue }
    }

    var preloadedAppConfig: AppConfig? {
        get { storage[PreloadedAppConfigKey.self] }
        set { storage[PreloadedAppConfigKey.self] = newValue }
    }
}

// MARK: - Test defaults

extension AppConfig {
    /// All-defaults config keyed on local auth, in-memory SQLite. Used by
    /// `makeTestApp` and by the lazy fallback in `Application.appConfig`.
    static func testDefaults(
        authMode: AuthMode = .local,
        database: DatabaseSettings = .sqliteInMemory()
    ) -> AppConfig {
        let auth = AuthConfig(
            mode: authMode,
            requestedMode: authMode,
            nonSSOModesEnabled: true,
            ssoAdminUsers: [],
            ssoInstructorUsers: []
        )
        return AppConfig(
            auth: auth,
            oidc: .default,
            security: .default,
            scanMode: .default,
            database: database,
            lockout: .default,
            workers: .default,
            brightspace: nil,
            // Mirror production defaults (enabled by default) so test apps
            // exercise the same observability code paths the runtime uses.
            diagnostics: DiagnosticsConfiguration(
                enabled: true,
                verboseRequestTiming: false,
                jobMetricRetentionDays: 30,
                runnerSnapshotRetentionDays: 14,
                activeRunnerWindowSeconds: 120,
                recentMetricsWindowHours: 24,
                pruneIntervalHours: 24,
                auditLogRetentionDays: 90
            ),
            alerts: .default
        )
    }
}
