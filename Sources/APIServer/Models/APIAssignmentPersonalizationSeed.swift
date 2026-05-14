// APIServer/Models/APIAssignmentPersonalizationSeed.swift
//
// Phase 1 of issue #461 — per-(user, assignment) seed.
//
// The seed value is a server-generated random 32-byte hex string (64 chars),
// surfaced to grading subprocesses via `CHICKADEE_ASSIGNMENT_SEED`. It is
// never exposed to client UI or to the student's notebook.

import Fluent
import Vapor

final class APIAssignmentPersonalizationSeed: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: all mutations happen within Vapor's request context.
    static let schema = "assignment_personalization_seeds"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userID: UUID

    @Field(key: "assignment_id")
    var assignmentID: UUID

    @Field(key: "seed_value")
    var seedValue: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, userID: UUID, assignmentID: UUID, seedValue: String) {
        self.id = id
        self.userID = userID
        self.assignmentID = assignmentID
        self.seedValue = seedValue
    }
}
