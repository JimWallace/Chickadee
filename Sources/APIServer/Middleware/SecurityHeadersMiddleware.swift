// APIServer/Middleware/SecurityHeadersMiddleware.swift
//
// Adds defence-in-depth HTTP security headers to every response.
//
// Headers added:
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
//   Strict-Transport-Security
//     Set only when HTTPS enforcement is enabled.  Pinning HSTS during
//     local-http development would break dev workflows; the gate via
//     `AppSecurityConfiguration.enforceHTTPS` matches the same trust signal
//     used by `HTTPSRedirectMiddleware`.

import Vapor

struct SecurityHeadersMiddleware: AsyncMiddleware {
    /// CSP for application pages.  Permissive enough to keep JupyterLite,
    /// Pyodide, and the CodeMirror-based assignment editor functional:
    ///   - 'unsafe-eval' is required by Pyodide's WASM bootstrap.
    ///   - 'unsafe-inline' covers inline `<script>` and `onclick=` handlers
    ///     in the Leaf templates.
    ///   - blob: in worker-src is required by JupyterLite's web workers.
    ///   - https://cdn.jsdelivr.net is whitelisted because the notebook,
    ///     browser-runner, and instructor-validate flows load Pyodide and
    ///     jszip from there at runtime, and `pyodide-worker.js` does an
    ///     `importScripts(...)` from the same origin.  Pyodide also fetches
    ///     Python wheels via `fetch` from the same indexURL, hence
    ///     `connect-src`.
    ///   - https://esm.sh is whitelisted because the new-assignment editor
    ///     imports CodeMirror modules from there.
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
        "script-src 'self' 'unsafe-eval' 'unsafe-inline' blob: https://cdn.jsdelivr.net https://esm.sh",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data: blob:",
        "font-src 'self' data:",
        "worker-src 'self' blob: https://cdn.jsdelivr.net",
        "child-src 'self' blob:",
        "connect-src 'self' https://cdn.jsdelivr.net https://esm.sh",
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

    /// Two-year HSTS with subdomain coverage. Preload is intentionally NOT
    /// asserted — operators must explicitly opt in to preload separately,
    /// since it's near-impossible to undo.
    static let defaultStrictTransportSecurity: String = "max-age=63072000; includeSubDomains"

    let cspBaseDirectives: [String]
    let permissionsPolicy: String
    let strictTransportSecurity: String?

    init(
        cspBaseDirectives: [String] = Self.defaultContentSecurityPolicyBase,
        permissionsPolicy: String = Self.defaultPermissionsPolicy,
        strictTransportSecurity: String? = nil
    ) {
        self.cspBaseDirectives = cspBaseDirectives
        self.permissionsPolicy = permissionsPolicy
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
        response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        response.headers.replaceOrAdd(name: "X-Frame-Options", value: "SAMEORIGIN")
        response.headers.replaceOrAdd(name: "Referrer-Policy", value: "strict-origin-when-cross-origin")
        response.headers.replaceOrAdd(name: "Content-Security-Policy", value: csp)
        response.headers.replaceOrAdd(name: "Permissions-Policy", value: permissionsPolicy)
        if let hsts = strictTransportSecurity {
            response.headers.replaceOrAdd(name: "Strict-Transport-Security", value: hsts)
        }
        return response
    }

    /// The SSO `end_session_endpoint` is an external origin the browser is
    /// redirected to after POST /logout.  Without it in form-action, the
    /// redirect chain is blocked and "Log out" silently does nothing.
    private func formActionExtras(for request: Request) -> [String] {
        guard
            let endpoint = request.application.oidcConfig?.discovery.endSessionEndpoint,
            let origin = Self.cspOrigin(of: endpoint)
        else { return [] }
        return [origin]
    }
}
