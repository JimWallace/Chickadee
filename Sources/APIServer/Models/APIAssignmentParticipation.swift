// APIServer/Models/APIAssignmentParticipation.swift
//
// Durable per-(user, assignment) participation record.
//
// One row is written the first time a student is given an assignment's
// materials (opens the notebook page or the upload form while it is open
// to them).  It is the authoritative answer to "has this student engaged
// with this assignment", used to keep a closed assignment reachable for
// students who started it — without re-deriving that fact from the
// ephemeral on-disk notebook working copy (wiped on redeploy) or from the
// personalization seed (a personalization primitive that only exists for
// personalized assignments).

import Fluent
import Vapor

final class APIAssignmentParticipation: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: all mutations happen within Vapor's request context.
    static let schema = "assignment_participations"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userID: UUID

    @Field(key: "assignment_id")
    var assignmentID: UUID

    @Timestamp(key: "first_accessed_at", on: .create)
    var firstAccessedAt: Date?

    init() {}

    init(id: UUID? = nil, userID: UUID, assignmentID: UUID) {
        self.id = id
        self.userID = userID
        self.assignmentID = assignmentID
    }
}
