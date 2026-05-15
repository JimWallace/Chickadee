// APIServer/Bootstrap/AppMiddleware.swift
//
// Order-sensitive middleware registration plus view/static-file setup.
// The order here is load-bearing:
//
//   LeafErrorMiddleware     — outermost so it catches every downstream error
//   HTTPSRedirectMiddleware — only when enforceHTTPS, before sessions
//   sessions.middleware
//   UserSessionAuthenticator
//   UserActivityMiddleware
//   UserFileNamespaceMiddleware
//   ScanModeMiddleware      — gates destructive POSTs in scan windows
//   FileMiddleware          — short-circuits the chain for static files,
//                             so all *prior* middleware run only for
//                             dynamic Leaf-rendered pages
//   COEPMiddleware          — sets Cross-Origin-Embedder-Policy headers
//                             on dynamic pages (NOT on JupyterLite static
//                             assets, since the service worker produces
//                             synthetic responses without CORP headers)
//   SecurityHeadersMiddleware
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
        HTTPCookies.Value(
            string: sessionID.string,
            expires: Date(timeIntervalSinceNow: 60 * 60 * 24 * 7),  // one week
            maxAge: nil,
            domain: nil,
            path: "/",
            isSecure: securityConfiguration.sessionCookieSecure,
            isHTTPOnly: true,
            sameSite: .lax
        )
    }
    app.sessions.configuration = sessionConfig

    // MARK: - Middleware (order matters)

    // Error page middleware must be outermost so it catches errors from all
    // subsequent middleware and route handlers.
    app.middleware.use(LeafErrorMiddleware())
    if securityConfiguration.enforceHTTPS {
        app.middleware.use(HTTPSRedirectMiddleware(configuration: securityConfiguration))
    }
    app.middleware.use(app.sessions.middleware)
    app.middleware.use(UserSessionAuthenticator())
    app.middleware.use(UserActivityMiddleware(debounceWindow: 60))
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
    // HSTS is set only when HTTPS enforcement is active. Pinning Strict-
    // Transport-Security against a dev http://localhost server would brick
    // local browsers; the enforceHTTPS gate matches HTTPSRedirectMiddleware.
    let hstsValue: String? =
        securityConfiguration.enforceHTTPS
        ? SecurityHeadersMiddleware.defaultStrictTransportSecurity
        : nil
    app.middleware.use(SecurityHeadersMiddleware(strictTransportSecurity: hstsValue))
}
