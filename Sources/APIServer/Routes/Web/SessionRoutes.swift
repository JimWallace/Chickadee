// APIServer/Routes/Web/SessionRoutes.swift
//
// Lightweight session keep-alive used by the client inactivity watchdog
// (idle-logout.js).  Two callers:
//
//   1. "Stay signed in" on the idle-warning modal — an explicit human action
//      that resets the idle clock.
//   2. A throttled ping while the student is actively working inside the
//      JupyterLite notebook iframe.  In-editor work makes no HTTP request to
//      Chickadee, so without this the server's `last_seen_at` would go stale
//      and the next-request gate (SessionIdleTimeoutMiddleware) would log out
//      an actively-working student.
//
// Registered in the authenticated route group, so it sits behind
// SessionIdleTimeoutMiddleware: a request that arrives *after* the idle
// ceiling is already bounced (302 → /login or 401) before it reaches this
// handler.  Reaching the handler therefore means the session is still inside
// the ceiling and it is safe to refresh `last_seen_at` to now.

import Fluent
import Foundation
import Vapor

struct SessionRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let session = routes.grouped("session")
        session.post("keepalive", use: keepAlive)
    }

    @Sendable
    func keepAlive(req: Request) async throws -> KeepAliveResponse {
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else {
            throw AppError.internalFailure(reason: "Authenticated user has no ID")
        }

        // Force-refresh regardless of UserActivityMiddleware's debounce: a
        // deliberate keep-alive must reset the full idle window.
        let now = Date()
        user.lastSeenAt = now
        try await APIUser.query(on: req.db)
            .filter(\.$id == userID)
            .set(\.$lastSeenAt, to: now)
            .update()

        let timeout = Int(req.application.securityConfiguration.sessionIdleTimeoutSeconds)
        return KeepAliveResponse(secondsRemaining: max(0, timeout))
    }
}

struct KeepAliveResponse: Content {
    /// Authoritative idle window after this refresh, in seconds. The client
    /// resets its deadline to `now + secondsRemaining` so its countdown can't
    /// drift from the server. Zero means the gate is disabled.
    let secondsRemaining: Int
}
