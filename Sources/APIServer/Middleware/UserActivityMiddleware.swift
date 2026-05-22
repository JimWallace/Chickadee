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

    /// The activity-refresh debounce must stay safely below the idle timeout.
    /// `SessionIdleTimeoutMiddleware` logs a user out once `last_seen_at` is
    /// older than the ceiling, and this debounce caps how fresh `last_seen_at`
    /// can be — so if the debounce is >= the ceiling, an *actively browsing*
    /// user's row never refreshes in time and they get logged out mid-activity
    /// (with no warning, since server-side logouts can't show one). With the
    /// standard 30-minute ceiling the 60 s cap dominates and behaviour is
    /// unchanged; with a short ceiling (e.g. a 1-minute test config) the window
    /// shrinks to a third of it so navigation keeps the session alive. A
    /// disabled gate (timeout <= 0) keeps the plain 60 s DB-write optimization.
    static func debounceWindow(forIdleTimeoutSeconds timeout: TimeInterval) -> TimeInterval {
        guard timeout > 0 else { return 60 }
        return min(60, timeout / 3)
    }

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
