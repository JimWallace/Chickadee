import Fluent
import Foundation
import Vapor

/// One login-rate-limit event: either a POST hitting the per-IP window
/// (`scope == "ip"`) or a failed login against a username
/// (`scope == "user_failure"`). Stored in the database so the sliding-window
/// counts are shared across server processes — with the old in-memory
/// `LoginAttemptStore`, N instances behind a load balancer meant N× the
/// configured per-IP rate and lockouts that only counted same-instance
/// failures (2026-07 audit, #1154). Rows are pruned per-key on write and
/// globally by a throttled sweep in the middleware.
final class LoginAttempt: Model, @unchecked Sendable {
    // @unchecked Sendable: written once at creation, never mutated after.
    static let schema = "login_attempts"

    enum Scope {
        static let ip = "ip"
        static let userFailure = "user_failure"
    }

    @ID(key: .id)
    var id: UUID?

    @Field(key: "scope")
    var scope: String

    @Field(key: "attempt_key")
    var attemptKey: String

    @Field(key: "occurred_at")
    var occurredAt: Date

    init() {}

    init(scope: String, attemptKey: String, occurredAt: Date) {
        self.scope = scope
        self.attemptKey = attemptKey
        self.occurredAt = occurredAt
    }
}
