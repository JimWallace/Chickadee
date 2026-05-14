// APIServer/Middleware/SecurityHeadersMiddleware.swift
//
// Adds defence-in-depth HTTP security headers to every response.
//
// Headers added:
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

import Vapor

struct SecurityHeadersMiddleware: AsyncMiddleware {
    func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        let response = try await next.respond(to: request)
        response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        response.headers.replaceOrAdd(name: "X-Frame-Options", value: "SAMEORIGIN")
        response.headers.replaceOrAdd(name: "Referrer-Policy", value: "strict-origin-when-cross-origin")
        return response
    }
}
