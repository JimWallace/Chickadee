// APIServer/Middleware/UserActivityMiddleware.swift

import Fluent
import Vapor

/// Refreshes `last_seen_at` on the authenticated user's row, debounced to
/// at most once per `debounceWindow`.  Without this, `last_login_at`
/// freezes at the moment a cookie session was first established and the
/// admin/instructor dashboards show "active 2 weeks ago" for a user who
/// has been browsing daily.  Runs after `UserSessionAuthenticator`, so
/// it sees a fully-loaded `APIUser` when one resolves and is a no-op for
/// unauthenticated traffic.
struct UserActivityMiddleware: AsyncMiddleware {
    let debounceWindow: TimeInterval

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        if let user = request.auth.get(APIUser.self), let userID = user.id {
            let now = Date()
            let needsUpdate: Bool
            if let last = user.lastSeenAt {
                needsUpdate = now.timeIntervalSince(last) >= debounceWindow
            } else {
                needsUpdate = true
            }
            if needsUpdate {
                user.lastSeenAt = now
                _ = try? await APIUser.query(on: request.db)
                    .filter(\.$id == userID)
                    .set(\.$lastSeenAt, to: now)
                    .update()
            }
        }
        return try await next.respond(to: request)
    }
}
