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
    app.lifecycle.use(AssignmentDeadlineLifecycleHandler())
    app.lifecycle.use(StuckSubmissionReaperLifecycleHandler())
    app.lifecycle.use(SessionReaperLifecycleHandler())
    app.lifecycle.use(
        AuditLogReaperLifecycleHandler(
            maxAge: TimeInterval(appConfig.diagnostics.auditLogRetentionDays) * 86_400
        )
    )
    app.lifecycle.use(ServerHealthAlertLifecycleHandler())

    // MCP OAuth table cleanup (only when the MCP endpoint is enabled).
    if appConfig.mcp.enabled {
        app.lifecycle.use(MCPOAuthReaperLifecycleHandler())
    }

    // BrightSpace grade sync (only registered when env vars are present).
    if let bsConfig = appConfig.brightspace {
        app.brightSpaceSyncConfig = bsConfig
        app.brightSpaceClient = BrightSpaceAPIClient(config: bsConfig)
        app.lifecycle.use(BrightSpaceGradeSyncLifecycleHandler())
        app.logger.info("BrightSpace grade sync enabled (org unit IDs configured per-course)")
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
