// APIServer/Middleware/SecurityHeadersMiddleware.swift
//
// Adds defence-in-depth HTTP security headers to every response.
//
// Headers added:
//
//   Cache-Control: no-store (text/html responses only)
//     Authenticated application pages must never be cached. Without this a
//     browser will serve the dashboard from its disk cache / back-forward
//     cache after the user logs out — so clicking a link or hitting Back
//     shows a logged-in view even though the server-side session is gone.
//     Scoped to text/html so versioned static assets (Pyodide, JupyterLite,
//     CodeMirror, images) keep their long-lived caching.
//
//   X-Content-Type-Options: nosniff
//     Prevents browsers from MIME-sniffing a response away from the declared
//     Content-Type. Stops certain content-injection attacks.
//
//   X-Frame-Options: SAMEORIGIN
//     Blocks this page from being embedded in an <iframe> on a different
//     origin, mitigating clickjacking. Covered by CSP frame-ancestors in
//     modern browsers, but X-Frame-Options handles older ones.
//
//   Referrer-Policy: strict-origin-when-cross-origin
//     Sends the full URL as Referer for same-origin requests, but only the
//     origin (no path/query) for cross-origin requests, and nothing at all
//     for downgrades (HTTPS → HTTP). Prevents leaking submission IDs or
//     assignment paths to third-party resources.
//
//   Content-Security-Policy
//     Tight-ish CSP that still allows JupyterLite + Pyodide (which both
//     require 'unsafe-eval' for in-browser WASM execution).  Inline scripts
//     and styles are permitted today because the Leaf templates use inline
//     event handlers and style attributes; tightening to nonces is a
//     follow-up.
//
//   Permissions-Policy
//     Nothing in Chickadee uses camera, microphone, or geolocation —
//     explicitly deny them so a future XSS can't escalate to media capture.
//
//   Cross-Origin-Opener-Policy: same-origin
//     Severs the `window.opener` reference when our pages are opened from a
//     third-party origin, mitigating tab-nabbing attacks and isolating our
//     browsing-context group.  Most Chickadee auth flows are redirects, not
//     popups, so cutting the opener reference does not break anything.  The
//     exception is the MCP OAuth consent screen: a connector (e.g. Claude)
//     may drive `/oauth/authorize` in a popup and expect a
//     `window.opener.postMessage` handshake after the redirect, which
//     `same-origin` would sever.  A handler can therefore relax COOP for a
//     single response via `SecurityHeadersMiddleware.setOpenerPolicy(_:on:)`.
//
//   Cross-Origin-Resource-Policy: same-origin
//     Stops third-party origins from embedding our resources (scripts,
//     stylesheets, images) via `<script src=...>` / `<img src=...>` etc.
//     Chickadee assets are only consumed by Chickadee pages, so this is
//     pure defence-in-depth.
//
//   Cross-Origin-Embedder-Policy is intentionally NOT set here.
//     `require-corp` blocks the JupyterLite iframe (its service worker
//     synthesises responses without CORP headers).  `COEPMiddleware`
//     opts the narrow set of pages that genuinely need cross-origin
//     isolation (currently just `/validate`) into the strict policy.
//
//   Strict-Transport-Security
//     Set only when HTTPS enforcement is enabled.  Pinning HSTS during
//     local-http development would break dev workflows; the gate via
//     `AppSecurityConfiguration.enforceHTTPS` matches the same trust signal
//     used by `HTTPSRedirectMiddleware`.

import Vapor

struct SecurityHeadersMiddleware: AsyncMiddleware {
    /// Per-request extra `form-action` CSP origins.  A handler that renders a
    /// page whose form submits (directly or via a redirect) to a validated
    /// cross-origin URL sets this so the global `form-action 'self'` doesn't
    /// block the navigation.  The MCP consent page uses it: its Authorize
    /// button 303s to the OAuth client's registered `redirect_uri`, and Chrome
    /// / Firefox enforce `form-action` across that redirect chain.
    private struct FormActionOriginsKey: StorageKey {
        typealias Value = [String]
    }

    /// Per-request `Cross-Origin-Opener-Policy` override.  Lets a handler relax
    /// the default `same-origin` for a single response (e.g. the OAuth consent
    /// page, which a connector may open as a popup that needs its `opener`).
    private struct OpenerPolicyKey: StorageKey {
        typealias Value = String
    }

    /// Appends a validated origin (`scheme://host[:port]`) to this response's
    /// `form-action` allow-list.  No-op when `origin` is nil.
    static func allowFormAction(_ origin: String?, on request: Request) {
        guard let origin else { return }
        var origins = request.storage[FormActionOriginsKey.self] ?? []
        if !origins.contains(origin) { origins.append(origin) }
        request.storage[FormActionOriginsKey.self] = origins
    }

    /// Overrides the `Cross-Origin-Opener-Policy` header for this one response.
    static func setOpenerPolicy(_ value: String, on request: Request) {
        request.storage[OpenerPolicyKey.self] = value
    }

    /// CSP for application pages.  Permissive enough to keep JupyterLite,
    /// Pyodide, and the CodeMirror-based assignment editor functional:
    ///   - 'unsafe-eval' is required by Pyodide's WASM bootstrap.
    ///   - 'unsafe-inline' covers inline `<script>` and `onclick=` handlers
    ///     in the Leaf templates.
    ///   - blob: in worker-src is required by JupyterLite's web workers.
    ///
    /// jszip, CodeMirror, and Pyodide are all vendored under `Public/` (see
    /// `scripts/setup-vendor.sh`).  There is ONE canonical Pyodide, served at
    /// `/pyodide`, loaded by both the JupyterLite editor kernel (via
    /// `pyodideUrl` in `Tools/jupyterlite/jupyter-lite.json`) and Chickadee's
    /// own browser paths (browser-runner grading, `/validate`, setup-edit).
    /// Every browser asset is therefore same-origin, so NO third-party origin
    /// appears in the policy.
    ///
    /// History worth keeping: the editor kernel used to load Pyodide from
    /// `cdn.jsdelivr.net` (the jupyterlite-pyodide-kernel default).  #574
    /// dropped the CDN allowance assuming self-hosting was complete — but the
    /// editor had never been repointed, so its kernel broke (a student-facing
    /// outage).  The editor is now served the vendored copy, so the allowance
    /// is gone for good.  Two guards keep a CDN dependency from creeping back
    /// in: `cSPHasNoExternalScriptConnectOrWorkerOrigins` here, and the
    /// `pyodideUrl`-is-same-origin check in `scripts/verify-jupyterlite.sh`.
    /// Tighten with per-response nonces in a follow-up.
    ///
    /// `form-action` is rendered per-request so the IdP origin from
    /// `app.oidcConfig?.discovery.endSessionEndpoint` can be appended when
    /// SSO is configured.  Without that, Chrome (and recent Firefox) enforce
    /// form-action across the redirect chain and block the POST /logout →
    /// 303 → end_session_endpoint navigation, breaking the SSO "Log out"
    /// button.
    static let defaultContentSecurityPolicyBase: [String] = [
        "default-src 'self'",
        "script-src 'self' 'unsafe-eval' 'unsafe-inline' blob:",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data: blob:",
        "font-src 'self' data:",
        "worker-src 'self' blob:",
        "child-src 'self' blob:",
        "connect-src 'self'",
        "frame-ancestors 'self'",
        "base-uri 'self'",
        "object-src 'none'",
    ]

    /// CSP used when no extra form-action origins apply (e.g. local-only mode
    /// or pre-OIDC-load).  Kept around for tests that pin the literal header.
    static let defaultContentSecurityPolicy: String = renderCSP(
        base: defaultContentSecurityPolicyBase,
        formActionOrigins: []
    )

    /// Builds the CSP string from the base directives plus a `form-action`
    /// directive whose allow-list always includes `'self'` and any extra
    /// origins passed in.
    static func renderCSP(base: [String], formActionOrigins: [String]) -> String {
        var sources = ["'self'"]
        for origin in formActionOrigins where !sources.contains(origin) {
            sources.append(origin)
        }
        var directives = base
        directives.append("form-action " + sources.joined(separator: " "))
        return directives.joined(separator: "; ")
    }

    /// Extracts the scheme://host[:port] origin from a URL string, suitable
    /// for use as a CSP source expression.  Returns nil for malformed input
    /// or schemes without a host (e.g. `data:`, `mailto:`).
    static func cspOrigin(of urlString: String) -> String? {
        guard
            let components = URLComponents(string: urlString),
            let scheme = components.scheme,
            let host = components.host, !host.isEmpty
        else { return nil }
        if let port = components.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    /// Permissions-Policy denying browser features Chickadee never uses.
    static let defaultPermissionsPolicy: String = [
        "camera=()",
        "microphone=()",
        "geolocation=()",
        "payment=()",
        "usb=()",
        "magnetometer=()",
        "accelerometer=()",
        "gyroscope=()",
    ].joined(separator: ", ")

    /// Cross-Origin-Opener-Policy default. `same-origin` is the strictest
    /// value supported by every modern browser and is safe whenever the app
    /// does not need to talk to popups it opens. Chickadee's OIDC + logout
    /// flows are redirects, not popups, so this is universally applicable.
    static let defaultCrossOriginOpenerPolicy: String = "same-origin"

    /// Cross-Origin-Resource-Policy default. `same-origin` prevents third
    /// parties from embedding our scripts, stylesheets, images, etc.
    static let defaultCrossOriginResourcePolicy: String = "same-origin"

    /// Two-year HSTS with subdomain coverage. Preload is intentionally NOT
    /// asserted — operators must explicitly opt in to preload separately,
    /// since it's near-impossible to undo.
    static let defaultStrictTransportSecurity: String = "max-age=63072000; includeSubDomains"

    let cspBaseDirectives: [String]
    let permissionsPolicy: String
    let crossOriginOpenerPolicy: String
    let crossOriginResourcePolicy: String
    let strictTransportSecurity: String?

    init(
        cspBaseDirectives: [String] = Self.defaultContentSecurityPolicyBase,
        permissionsPolicy: String = Self.defaultPermissionsPolicy,
        crossOriginOpenerPolicy: String = Self.defaultCrossOriginOpenerPolicy,
        crossOriginResourcePolicy: String = Self.defaultCrossOriginResourcePolicy,
        strictTransportSecurity: String? = nil
    ) {
        self.cspBaseDirectives = cspBaseDirectives
        self.permissionsPolicy = permissionsPolicy
        self.crossOriginOpenerPolicy = crossOriginOpenerPolicy
        self.crossOriginResourcePolicy = crossOriginResourcePolicy
        self.strictTransportSecurity = strictTransportSecurity
    }

    func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        let response = try await next.respond(to: request)
        let csp = Self.renderCSP(
            base: cspBaseDirectives,
            formActionOrigins: formActionExtras(for: request)
        )
        // Never cache authenticated HTML — a logged-out browser must re-ask
        // the server rather than render a stale dashboard from its bf-cache or
        // disk cache. Scoped to text/html so static assets stay cacheable.
        if let contentType = response.headers.first(name: .contentType),
            contentType.hasPrefix("text/html")
        {
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        }
        response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        response.headers.replaceOrAdd(name: "X-Frame-Options", value: "SAMEORIGIN")
        response.headers.replaceOrAdd(name: "Referrer-Policy", value: "strict-origin-when-cross-origin")
        response.headers.replaceOrAdd(name: "Content-Security-Policy", value: csp)
        response.headers.replaceOrAdd(name: "Permissions-Policy", value: permissionsPolicy)
        // COOP is set unconditionally; COEPMiddleware may override it for the
        // narrow set of pages that need cross-origin isolation, but its value
        // is `same-origin` too so the replaceOrAdd is a no-op there.  A handler
        // can relax it per-response (the OAuth consent popup) via the override.
        let coop = request.storage[OpenerPolicyKey.self] ?? crossOriginOpenerPolicy
        response.headers.replaceOrAdd(name: "Cross-Origin-Opener-Policy", value: coop)
        response.headers.replaceOrAdd(name: "Cross-Origin-Resource-Policy", value: crossOriginResourcePolicy)
        if let hsts = strictTransportSecurity {
            response.headers.replaceOrAdd(name: "Strict-Transport-Security", value: hsts)
        }
        return response
    }

    /// The SSO `end_session_endpoint` is an external origin the browser is
    /// redirected to after POST /logout.  Without it in form-action, the
    /// redirect chain is blocked and "Log out" silently does nothing.
    private func formActionExtras(for request: Request) -> [String] {
        // Per-request origins set by a handler (e.g. the OAuth consent page's
        // redirect_uri) come first, then the SSO end_session_endpoint origin.
        var origins = request.storage[FormActionOriginsKey.self] ?? []
        if let endpoint = request.application.oidcConfig?.discovery.endSessionEndpoint,
            let origin = Self.cspOrigin(of: endpoint), !origins.contains(origin)
        {
            origins.append(origin)
        }
        return origins
    }
}
