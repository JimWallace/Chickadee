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
//   EditorAssetFastPathMiddleware — serves the vendored editor asset trees
//                               (/jupyterlite/build, /jupyterlite/extensions,
//                               /pyodide, /vendor) BEFORE the session chain so
//                               a JupyterLite boot's hundreds of asset
//                               requests skip the per-request Fluent session
//                               lookup.  Whitelist-only: the auth-guarded
//                               /jupyterlite/…/files/users/ paths are not
//                               listed and still ride the full chain below.
//   sessions.middleware
//   UserSessionAuthenticator
//   SessionIdleTimeoutMiddleware — runs before UserActivityMiddleware
//                                   so it sees the previous request's
//                                   lastSeenAt (not a freshly-refreshed one)
//   UserActivityMiddleware
//   UserFileNamespaceMiddleware
//   ScanModeMiddleware      — gates destructive POSTs in scan windows
//   StaticAssetCacheMiddleware — stamps immutable Cache-Control on
//                             version-fingerprinted (`?v=`) static assets
//                             served by FileMiddleware
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
    // Vendored editor assets short-circuit here, before any session work.
    // See EditorAssetFastPathMiddleware for the whitelist + cache policy.
    app.middleware.use(
        EditorAssetFastPathMiddleware(publicDirectory: app.directory.publicDirectory))
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

    // Compress compressible response types (text, JS, JSON, SVG — Vapor's
    // allowlist) when the client advertises Accept-Encoding.  The shared
    // stylesheet and page scripts shrink ~4–8× on the wire.  Already-compressed
    // formats (zip, wasm, images, fonts) are not in the allowlist, so the
    // multi-megabyte Pyodide/JupyterLite payloads don't burn CPU recompressing.
    // HTML opts out per-response in SecurityHeadersMiddleware: pages embed the
    // per-session CSRF token, and compressing a secret alongside reflectable
    // request data is the precondition for BREACH-style compression oracles.
    app.http.server.configuration.responseCompression = .enabledForCompressibleTypes

    // MARK: - Views + static files

    app.views.use(.leaf)
    app.leaf.tags["csrfFormField"] = CSRFFormFieldTag()
    app.leaf.tags["csrfToken"] = CSRFTokenTag()
    app.leaf.tags["appVersion"] = AppVersionTag()
    app.leaf.tags["mcpEnabled"] = MCPEnabledTag()
    app.leaf.tags["sessionIdleTimeoutSeconds"] = SessionIdleTimeoutTag()
    app.leaf.tags["sessionIdleWarningSeconds"] = SessionIdleWarningTag()
    app.leaf.tags["rawJSON"] = RawJSONTag()
    // FileMiddleware short-circuits the responder chain (it returns without
    // calling next), so middleware registered AFTER it only runs for dynamic
    // Leaf-rendered pages — which is why COEPMiddleware (after it) covers the
    // dynamic notebook page, while NotebookAssetIsolationMiddleware (before it)
    // is needed to decorate the static /jupyterlite/* responses. By default the
    // JupyterLite assets get no COEP (long-standing behaviour). Cross-origin
    // isolation for the editor — the fix for the Pyodide main-thread freeze when
    // there's no SharedArrayBuffer and the service-worker sync fallback is
    // disabled — is opt-in via NOTEBOOK_CROSS_ORIGIN_ISOLATION (see
    // COEPMiddleware / NotebookAssetIsolationMiddleware).
    // Registered just OUTSIDE FileMiddleware so it can set immutable cache +
    // application/wasm headers on the content-hashed wasm runner served from
    // Public/runner-wasm/ (FileMiddleware short-circuits, so a middleware after
    // it never sees those responses).
    // Versioned-asset caching sits outside RunnerWasmCacheMiddleware so the
    // wasm middleware's more specific policies (immutable hashed wasm,
    // no-cache loader) win — StaticAssetCacheMiddleware never overwrites an
    // existing Cache-Control.
    app.middleware.use(StaticAssetCacheMiddleware())
    app.middleware.use(RunnerWasmCacheMiddleware())
    // Cross-origin isolation for the notebook editor (gated by
    // NOTEBOOK_CROSS_ORIGIN_ISOLATION, default off). The asset middleware runs
    // BEFORE FileMiddleware so it can decorate the short-circuited /jupyterlite/*
    // static responses; COEPMiddleware (after FileMiddleware) covers the dynamic
    // notebook page itself. Both no-op when the flag is off.
    let isolateNotebook = securityConfiguration.notebookCrossOriginIsolation
    app.middleware.use(NotebookAssetIsolationMiddleware(enabled: isolateNotebook))
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
    app.middleware.use(COEPMiddleware(isolateNotebook: isolateNotebook))
}
