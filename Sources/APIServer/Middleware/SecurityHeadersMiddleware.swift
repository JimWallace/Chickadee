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
    /// CSP for application pages.  Permissive enough to keep JupyterLite and
    /// Pyodide functional:
    ///   - 'unsafe-eval' is required by Pyodide's WASM bootstrap.
    ///   - 'unsafe-inline' covers inline `<script>` and `onclick=` handlers
    ///     in the Leaf templates.
    ///   - blob: in worker-src is required by JupyterLite's web workers.
    /// Tighten with per-response nonces in a follow-up.
    static let defaultContentSecurityPolicy: String = [
        "default-src 'self'",
        "script-src 'self' 'unsafe-eval' 'unsafe-inline' blob:",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data: blob:",
        "font-src 'self' data:",
        "worker-src 'self' blob:",
        "child-src 'self' blob:",
        "connect-src 'self'",
        "frame-ancestors 'self'",
        "form-action 'self'",
        "base-uri 'self'",
        "object-src 'none'",
    ].joined(separator: "; ")

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

    let contentSecurityPolicy: String
    let permissionsPolicy: String
    let strictTransportSecurity: String?

    init(
        contentSecurityPolicy: String = Self.defaultContentSecurityPolicy,
        permissionsPolicy: String = Self.defaultPermissionsPolicy,
        strictTransportSecurity: String? = nil
    ) {
        self.contentSecurityPolicy = contentSecurityPolicy
        self.permissionsPolicy = permissionsPolicy
        self.strictTransportSecurity = strictTransportSecurity
    }

    func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        let response = try await next.respond(to: request)
        response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        response.headers.replaceOrAdd(name: "X-Frame-Options", value: "SAMEORIGIN")
        response.headers.replaceOrAdd(name: "Referrer-Policy", value: "strict-origin-when-cross-origin")
        response.headers.replaceOrAdd(name: "Content-Security-Policy", value: contentSecurityPolicy)
        response.headers.replaceOrAdd(name: "Permissions-Policy", value: permissionsPolicy)
        if let hsts = strictTransportSecurity {
            response.headers.replaceOrAdd(name: "Strict-Transport-Security", value: hsts)
        }
        return response
    }
}
