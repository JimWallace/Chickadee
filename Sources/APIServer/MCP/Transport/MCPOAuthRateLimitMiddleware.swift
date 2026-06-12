// APIServer/MCP/Transport/MCPOAuthRateLimitMiddleware.swift
//
// Per-IP sliding-window rate limit for the unauthenticated back-channel OAuth
// endpoints (/oauth/token, /oauth/revoke, /oauth/register).  `/oauth/register`
// in particular is open (anyone may register a client), so without this an
// attacker could flood the oauth_clients table; the limiter plus the
// MCPConfig.maxRegisteredClients backstop bound that.
//
// Reuses the app's LoginAttemptStore actor with a namespaced key ("mcp-oauth:")
// so the bookkeeping is shared and ephemeral, matching the /login limiter.
// POST-only; other methods pass through.

import Foundation
import Vapor

struct MCPOAuthRateLimitMiddleware: AsyncMiddleware {
    let perMinute: Int
    let trustForwardedFor: Bool

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard request.method == .POST else { return try await next.respond(to: request) }
        let ip = clientIPAddress(from: request, trustForwardedFor: trustForwardedFor)
        let allowed = await request.application.loginAttemptStore.recordAndCheckIP(
            ip: "mcp-oauth:\(ip)",
            now: Date(),
            windowSeconds: 60,
            max: perMinute
        )
        guard allowed else {
            request.logger.warning("MCP OAuth rate limit exceeded for IP \(ip)")
            let response = Response(status: .tooManyRequests)
            response.headers.replaceOrAdd(name: "Retry-After", value: "60")
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            try response.content.encode(["error": "rate_limited"])
            return response
        }
        return try await next.respond(to: request)
    }
}
