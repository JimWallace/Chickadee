// APIServer/Bootstrap/AppMiddleware.swift
//
// Order-sensitive middleware registration plus view/static-file setup.
// The order here is load-bearing:
//
//   SecurityHeadersMiddleware — outermost so it adds CSP / nosniff /
//                               Permissions-Policy to EVERY response,
//                               including 404s rendered by
//                               LeafErrorMiddleware, static assets served
//                               by FileMiddleware, and 301s from
//                               HTTPSRedirectMiddleware
//   LeafErrorMiddleware     — catches every downstream error
//   HTTPSRedirectMiddleware — only when enforceHTTPS, before sessions
//   sessions.middleware
//   UserSessionAuthenticator
//   SessionIdleTimeoutMiddleware — runs before UserActivityMiddleware
//                                   so it sees the previous request's
//                                   lastSeenAt (not a freshly-refreshed one)
//   UserActivityMiddleware
//   UserFileNamespaceMiddleware
//   ScanModeMiddleware      — gates destructive POSTs in scan windows
//   FileMiddleware          — short-circuits the chain for static files
//   COEPMiddleware          — sets Cross-Origin-Embedder-Policy headers
//                             on dynamic pages (NOT on JupyterLite static
//                             assets, since the service worker produces
//                             synthetic responses without CORP headers)
//
// Storage seeding for auth/security configs happens here too because
// the middleware chain reads them via app.storage.
//
// Extracted from configure(_:) in #496.

import CSRF
import Leaf
import Vapor

func bootstrapAppMiddleware(_ app: Application, appConfig: AppConfig) {
    let securityConfiguration = appConfig.security
    let scanModeConfiguration = appConfig.scanMode

    // MARK: - Storage seeding for auth/security configs

    app.storage[AuthModeKey.self] = appConfig.auth.mode
    app.storage[SecurityConfigurationKey.self] = securityConfiguration
    app.storage[ScanModeConfigurationKey.self] = scanModeConfiguration
    app.storage[LoginRateLimitConfigurationKey.self] = appConfig.lockout
    app.storage[SSOAdminUsersKey.self] = appConfig.auth.ssoAdminUsers
    app.storage[SSOInstructorUsersKey.self] = appConfig.auth.ssoInstructorUsers

    // MARK: - Sessions (Fluent-backed; persisted in the database)

    app.sessions.use(.fluent)
    var sessionConfig = app.sessions.configuration
    sessionConfig.cookieFactory = { sessionID in
        chickadeeSessionCookie(
            sessionID: sessionID,
            isSecure: securityConfiguration.sessionCookieSecure
        )
    }
    app.sessions.configuration = sessionConfig

    // MARK: - Middleware (order matters)

    // Security headers run *outermost* so that CSP, X-Content-Type-Options,
    // Permissions-Policy, etc. land on every response — including 404s
    // produced by LeafErrorMiddleware, static-asset responses served by
    // FileMiddleware, and 301s issued by HTTPSRedirectMiddleware.  Each of
    // those middlewares either short-circuits the chain or builds its own
    // response, so middleware registered *after* them never sees the
    // response on the way back.  HSTS is still gated on enforceHTTPS via
    // the strictTransportSecurity argument below.
    let hstsValue: String? =
        securityConfiguration.enforceHTTPS
        ? SecurityHeadersMiddleware.defaultStrictTransportSecurity
        : nil
    app.middleware.use(SecurityHeadersMiddleware(strictTransportSecurity: hstsValue))

    // Error page middleware sits beneath SecurityHeadersMiddleware so it
    // catches errors from all subsequent middleware and route handlers.
    app.middleware.use(LeafErrorMiddleware())
    if securityConfiguration.enforceHTTPS {
        app.middleware.use(HTTPSRedirectMiddleware(configuration: securityConfiguration))
    }
    app.middleware.use(app.sessions.middleware)
    app.middleware.use(UserSessionAuthenticator())
    if securityConfiguration.sessionIdleTimeoutSeconds > 0 {
        app.middleware.use(
            SessionIdleTimeoutMiddleware(
                idleTimeoutSeconds: securityConfiguration.sessionIdleTimeoutSeconds
            )
        )
    }
    app.middleware.use(
        UserActivityMiddleware(
            debounceWindow: UserActivityMiddleware.debounceWindow(
                forIdleTimeoutSeconds: securityConfiguration.sessionIdleTimeoutSeconds
            )
        )
    )
    app.middleware.use(UserFileNamespaceMiddleware())
    // Scan-mode seatbelt: when SCAN_MODE=true is set in the environment, the
    // middleware 503s POSTs against destructive routes (submissions, test-setup
    // uploads, retests, user delete/role) so an in-progress vulnerability scan
    // can crawl the app without polluting prod data or fanning out work.
    if scanModeConfiguration.enabled {
        app.logger.warning(
            "SCAN_MODE=true — destructive POST endpoints are returning 503. Disable after the scan window."
        )
    }
    app.middleware.use(ScanModeMiddleware(configuration: scanModeConfiguration))
    // Allow notebook uploads from the assignment-creation flow.
    app.routes.defaultMaxBodySize = "10mb"

    // MARK: - Views + static files

    app.views.use(.leaf)
    app.leaf.tags["csrfFormField"] = CSRFFormFieldTag()
    app.leaf.tags["csrfToken"] = CSRFTokenTag()
    app.leaf.tags["appVersion"] = AppVersionTag()
    app.leaf.tags["mcpEnabled"] = MCPEnabledTag()
    app.leaf.tags["sessionIdleTimeoutSeconds"] = SessionIdleTimeoutTag()
    app.leaf.tags["sessionIdleWarningSeconds"] = SessionIdleWarningTag()
    app.leaf.tags["rawJSON"] = RawJSONTag()
    // FileMiddleware is registered first so static files are served directly.
    // It short-circuits the responder chain (returns without calling next), so
    // middleware registered after it only runs for dynamic Leaf-rendered pages.
    // This is intentional: JupyterLite's static files must NOT receive COEP
    // require-corp because JupyterLite's service worker produces synthetic
    // responses (virtual filesystem, contents API) that lack Cross-Origin-
    // Resource-Policy headers.  COEP on the page would block those responses
    // and prevent the app from initialising.  Modern Pyodide (0.27+) does not
    // require SharedArrayBuffer — it uses a service-worker-based synchronisation
    // fallback — so cross-origin isolation on the iframe document is unnecessary.
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
    app.middleware.use(COEPMiddleware())
}
