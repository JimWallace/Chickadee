// APIServer/Models/APISecretRevealUnlock.swift
//
// Durable per-(user, assignment) secret-reveal token spend.
//
// Each student holds one reveal token per assignment (when the assignment's
// `secret_reveal_enabled` toggle is on). Spending it is recorded here; the
// row's *existence* is the spent state, and secret-tier test results are then
// itemized on all of that student's submissions for the assignment. Course
// staff re-grant the token by deleting the row. Unrelated to auth/OAuth
// tokens — this is a gamified display unlock only; grades are unaffected
// (they already span every tier).

import Fluent
import Vapor

final class APISecretRevealUnlock: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: all mutations happen within Vapor's request context.
    static let schema = "secret_reveal_unlocks"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userID: UUID

    @Field(key: "assignment_id")
    var assignmentID: UUID

    @Timestamp(key: "spent_at", on: .create)
    var spentAt: Date?

    init() {}

    init(id: UUID? = nil, userID: UUID, assignmentID: UUID) {
        self.id = id
        self.userID = userID
        self.assignmentID = assignmentID
    }
}
