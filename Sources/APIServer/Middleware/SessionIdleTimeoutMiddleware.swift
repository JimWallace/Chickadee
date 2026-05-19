// APIServer/Middleware/SessionIdleTimeoutMiddleware.swift
//
// Idle (inactivity) session timeout.  When an authenticated user has not
// touched the server for more than `idleTimeoutSeconds`, this middleware
// drops the session before any route handler runs and forces the user
// back through the login flow.  Required by FIPPA / institutional
// security policy on student data systems.
//
// Activity is tracked via `APIUser.lastSeenAt`, which `UserActivityMiddleware`
// refreshes (debounced to once per 60 s) on every authenticated request.
// Because the activity middleware runs *after* this gate in the middleware
// chain, the `lastSeenAt` we read here is the value from the user's
// previous request — exactly what we need for an inactivity check.
//
// The middleware is a no-op when:
//   - the request is not authenticated (no APIUser on `req.auth`)
//   - the idle timeout is disabled (`idleTimeoutSeconds <= 0`)
//   - the user has no `lastSeenAt` yet (legacy row predating
//     UserActivityMiddleware — the next request will populate it)
//
// On expiry: any OIDC bearer tokens stashed in `req.session.data` are
// cleared (so a stale access/refresh token can't outlive the cookie),
// `req.auth.logout` and `req.session.unauthenticate` drop the auth state,
// an `auth.session_idle_timeout` audit row is written, and the response
// is either a redirect to `/login?error=timeout` (browser) or HTTP 401
// (API client).

import Foundation
import Vapor

struct SessionIdleTimeoutMiddleware: AsyncMiddleware {
    let idleTimeoutSeconds: TimeInterval

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard idleTimeoutSeconds > 0, let user = request.auth.get(APIUser.self) else {
            return try await next.respond(to: request)
        }

        guard let lastSeen = user.lastSeenAt else {
            return try await next.respond(to: request)
        }

        let idle = Date().timeIntervalSince(lastSeen)
        guard idle > idleTimeoutSeconds else {
            return try await next.respond(to: request)
        }

        await AuditLogger.record(
            action: .sessionIdleTimeout,
            targetType: .auth,
            targetID: user.id?.uuidString,
            metadata: [
                "username": user.username,
                "idle_seconds": String(Int(idle.rounded())),
                "timeout_seconds": String(Int(idleTimeoutSeconds)),
            ],
            actorOverride: user,
            on: request
        )

        // Mirror /logout's behaviour: nil out any OIDC bearer tokens before
        // dropping the auth state so they don't sit in the session row
        // after the user-facing session has expired.
        request.session.data["oidc_access_token"] = nil
        request.session.data["oidc_refresh_token"] = nil
        request.session.data["oidc_id_token"] = nil

        request.auth.logout(APIUser.self)
        request.session.unauthenticate(APIUser.self)

        if request.url.path.hasPrefix("/api/") {
            throw Abort(.unauthorized, reason: "Session timed out")
        }
        return request.redirect(to: "/login?error=timeout")
    }
}
