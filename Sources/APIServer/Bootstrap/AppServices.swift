// APIServer/Bootstrap/AppServices.swift
//
// Database configuration + migrations, lifecycle handlers, optional
// BrightSpace grade-sync wiring, and SSO config-validation warnings.
// Anything that wires up background services or schedules work goes
// here.
//
// Extracted from configure(_:) in #496.

import Fluent
import Vapor

func bootstrapAppServices(_ app: Application, appConfig: AppConfig) throws {
    try configureDatabase(app, settings: appConfig.database)
    registerMigrations(on: app)

    // Repair migration-history rows from the pre-`APIServer` module name so a
    // restored older snapshot (e.g. v0.4.172) doesn't re-run applied migrations.
    try reconcileLegacyMigrationNamespace(on: app)

    try app.autoMigrate().wait()
    app.lifecycle.use(ObservabilityLifecycleHandler())
    app.lifecycle.use(PeriodicSweepLifecycleHandler { $0.assignmentDeadlineMonitor })
    app.lifecycle.use(PeriodicSweepLifecycleHandler { $0.stuckSubmissionReaperMonitor })
    app.lifecycle.use(PeriodicSweepLifecycleHandler { $0.achievementEvaluationMonitor })
    app.lifecycle.use(PeriodicSweepLifecycleHandler { $0.sessionReaperMonitor })
    app.lifecycle.use(PeriodicSweepLifecycleHandler { $0.activityEventReaperMonitor })
    let auditLogMaxAge = TimeInterval(appConfig.diagnostics.auditLogRetentionDays) * 86_400
    app.lifecycle.use(
        PeriodicSweepLifecycleHandler { $0.auditLogReaperMonitor(maxAge: auditLogMaxAge) }
    )
    app.lifecycle.use(ServerHealthAlertLifecycleHandler())

    // One-time best-effort cleanup of pre-v0.4 notebook working-copy
    // artifacts (used to run on every notebook page view).
    app.lifecycle.use(LegacyNotebookCleanupLifecycleHandler())

    // MCP OAuth table cleanup (only when the MCP endpoint is mounted — grants
    // and codes exist in read_only mode too).
    if appConfig.mcp.mode.isMounted {
        app.lifecycle.use(PeriodicSweepLifecycleHandler { $0.mcpOAuthReaperMonitor })
    }

    // BrightSpace grade sync. Registered whenever the deployment app creds
    // (URL/App ID/App Key) are present; the user key may come from env or be
    // supplied later via the admin authorize flow (the sweep re-reads the
    // client each cycle, so authorization takes effect without a restart).
    if let bsApp = appConfig.brightspaceApp {
        app.brightSpaceAppCredentials = bsApp
        // Resolve the active identity now (migrations have run): a stored
        // (authorized) key wins, else an env-provided full config.
        let resolved: BrightSpaceSyncConfig?
        do {
            resolved = try app.eventLoopGroup.any().makeFutureWithTask {
                try await BrightSpaceCredentialStore.resolveSyncConfig(
                    app: bsApp, envConfig: appConfig.brightspace, on: app.db)
            }.wait()
        } catch {
            app.logger.warning(
                "BrightSpace: failed to load stored credential at startup: \(error.localizedDescription); falling back to env"
            )
            resolved = appConfig.brightspace
        }
        if let resolved {
            app.brightSpaceSyncConfig = resolved
            app.brightSpaceClient = BrightSpaceAPIClient(config: resolved)
            app.logger.info("BrightSpace grade sync enabled (org unit IDs configured per-course)")
        } else {
            app.logger.info(
                "BrightSpace configured but not authorized — authorize at /admin/brightspace")
        }
        app.lifecycle.use(BrightSpaceGradeSyncLifecycleHandler())
        app.lifecycle.use(PeriodicSweepLifecycleHandler { $0.learnRosterReadinessMonitor })
    }

    if appConfig.auth.mode != .local {
        logSSOConfigWarnings(app: app, appConfig: appConfig)
    }
}

private func logSSOConfigWarnings(app: Application, appConfig: AppConfig) {
    let authMode = appConfig.auth.mode
    let nonSSOModesEnabled = appConfig.auth.nonSSOModesEnabled
    if !nonSSOModesEnabled {
        app.logger.info(
            "Default auth mode is SSO. Set ENABLE_NON_SSO_AUTH_MODES=true to allow local/dual AUTH_MODE values."
        )
    }
    if let requestedAuthMode = appConfig.auth.requestedMode,
        requestedAuthMode != .sso,
        !nonSSOModesEnabled
    {
        app.logger.warning(
            "AUTH_MODE=\(requestedAuthMode.rawValue) ignored because ENABLE_NON_SSO_AUTH_MODES is not enabled; using sso."
        )
    }
    let securityConfiguration = appConfig.security
    if securityConfiguration.publicBaseURL == nil {
        app.logger.warning("AUTH_MODE is \(authMode.rawValue), but PUBLIC_BASE_URL is not set.")
    } else if securityConfiguration.publicBaseURL?.scheme?.lowercased() != "https" {
        let configured = securityConfiguration.publicBaseURL?.absoluteString ?? "(unset)"
        app.logger.warning("AUTH_MODE is \(authMode.rawValue), but PUBLIC_BASE_URL is not https: \(configured)")
    }
    if !securityConfiguration.sessionCookieSecure {
        app.logger.warning("AUTH_MODE is \(authMode.rawValue), but session cookies are not marked Secure.")
    }
    if appConfig.oidc.clientID == nil {
        app.logger.warning("AUTH_MODE is \(authMode.rawValue), but OIDC_CLIENT_ID is not set.")
    }
    if appConfig.oidc.clientSecret == nil {
        app.logger.warning("AUTH_MODE is \(authMode.rawValue), but OIDC_CLIENT_SECRET is not set.")
    }
}
