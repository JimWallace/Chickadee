// APIServer/Middleware/ScanModeMiddleware.swift
//
// "Scan mode" is an operational seatbelt for hosting a production deployment
// behind an active vulnerability scanner (e.g. HCL AppScan, OWASP ZAP).
// Enabled via the SCAN_MODE env var, this middleware short-circuits POST
// requests against routes that would otherwise pollute production data or
// fan out work (new submissions, test-setup uploads, retests, user deletes,
// role changes).  Login, dashboards, static files, and read-only endpoints
// continue to work so the scanner can still exercise the surface area we
// care about.
//
// The response is a deterministic 503 with `{"error":"scan_mode"}` so the
// scanner records the block as a non-finding rather than a generic 5xx.

import Vapor

struct ScanModeConfiguration: Sendable {
    let enabled: Bool

    static let `default` = ScanModeConfiguration(enabled: false)

    static func fromEnvironment() -> Self {
        ScanModeConfiguration(enabled: environmentBool("SCAN_MODE") ?? false)
    }
}

struct ScanModeMiddleware: AsyncMiddleware {
    let configuration: ScanModeConfiguration

    func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        guard configuration.enabled else {
            return try await next.respond(to: request)
        }
        guard request.method == .POST, Self.isGatedPath(request.url.path) else {
            return try await next.respond(to: request)
        }
        request.logger.info(
            "scan_mode: blocked POST \(request.url.path)"
        )
        let response = Response(status: .serviceUnavailable)
        try response.content.encode(["error": "scan_mode"])
        response.headers.replaceOrAdd(name: "Retry-After", value: "3600")
        return response
    }

    /// Path-matching for routes the scanner must not be allowed to trigger.
    /// Kept deliberately short and explicit; add to this list when a new
    /// destructive route is introduced.
    static func isGatedPath(_ path: String) -> Bool {
        // Strip any trailing slash for stable matching.
        let p = path.hasSuffix("/") ? String(path.dropLast()) : path

        // /api/v1/submissions, /api/v1/submissions/file,
        //   /api/v1/submissions/browser-result, /api/v1/submissions/runner-submit
        if p == "/api/v1/submissions" { return true }
        if p == "/api/v1/submissions/file" { return true }
        if p == "/api/v1/submissions/browser-result" { return true }
        if p == "/api/v1/submissions/runner-submit" { return true }

        // /api/v1/testsetups
        if p == "/api/v1/testsetups" { return true }

        // /testsetups/<id>/submit
        if p.hasPrefix("/testsetups/"), p.hasSuffix("/submit") { return true }

        // /instructor/<id>/retest and /instructor/<id>/submissions/<id>/retest
        if p.hasPrefix("/instructor/"), p.hasSuffix("/retest") { return true }

        // /admin/users/<id>/delete and /admin/users/<id>/role
        if p.hasPrefix("/admin/users/"),
            p.hasSuffix("/delete") || p.hasSuffix("/role")
        {
            return true
        }

        return false
    }
}

// MARK: - Application storage

struct ScanModeConfigurationKey: StorageKey {
    typealias Value = ScanModeConfiguration
}

extension Application {
    var scanModeConfiguration: ScanModeConfiguration {
        get { storage[ScanModeConfigurationKey.self] ?? .default }
        set { storage[ScanModeConfigurationKey.self] = newValue }
    }
}
