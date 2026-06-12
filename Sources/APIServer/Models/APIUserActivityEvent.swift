import Fluent
import Vapor

/// A lightweight "this user was active" ping, written by
/// `UserActivityMiddleware` for genuine (non-background-refresh) authenticated
/// requests, throttled to at most one row per user per
/// `ActivityEventThrottle.window` so a continuously-browsing user yields a
/// handful of rows per hour rather than one per request.
///
/// Unlike `APIUser.lastSeenAt` (a single live snapshot, overwritten on every
/// refresh), these rows accumulate over time, so they can reconstruct
/// *historical* "active users per time bucket" for the admin dashboard's
/// activity chart.  An hourly reaper trims rows past the longest charted
/// window so the table stays bounded.
final class APIUserActivityEvent: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: instances are only ever touched within Vapor's
    // request context, never shared across concurrency domains.
    static let schema = "user_activity_events"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userID: UUID

    /// The user's role at the time of the request, denormalised so a future
    /// role-split chart needs no migration.  Nullable per the project rule
    /// that forward-looking columns ship now and can be null until used.
    @OptionalField(key: "role")
    var role: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(userID: UUID, role: String?) {
        self.userID = userID
        self.role = role
    }
}
