// APIServer/Models/APIAssignmentExtension.swift
//
// Per-student deadline extension on an assignment.  An extension lets one
// student keep submitting past the assignment-wide deadline; the assignment
// itself remains closed for every other student.  See
// `AssignmentDeadlineService.requireOpenStudentAssignment(for:user:on:)` for
// the gate that consults this row.
//
// One row per (assignment, user) — enforced by the composite UNIQUE index in
// CreateAssignmentExtensions.

import Fluent
import Vapor

final class APIAssignmentExtension: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: all mutations happen within Vapor's request context.
    static let schema = "assignment_extensions"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "assignment_id")
    var assignmentID: UUID

    @Field(key: "user_id")
    var userID: UUID

    @Field(key: "extended_due_at")
    var extendedDueAt: Date

    @OptionalField(key: "note")
    var note: String?

    @OptionalField(key: "granted_by_user_id")
    var grantedByUserID: UUID?

    @Timestamp(key: "granted_at", on: .create)
    var grantedAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        assignmentID: UUID,
        userID: UUID,
        extendedDueAt: Date,
        note: String? = nil,
        grantedByUserID: UUID? = nil
    ) {
        self.id = id
        self.assignmentID = assignmentID
        self.userID = userID
        self.extendedDueAt = extendedDueAt
        self.note = note
        self.grantedByUserID = grantedByUserID
    }
}
