// APIServer/Models/APICompositeSpare.swift
//
// One spare slot of a class composite (docs/class-composite.md, slice 6b): a
// slot that no passing contribution fills, rendered by a student who finished
// their own. "Fill a hole" grades the student's passing submission again with
// the slot's inputs, and the result fills the row. A passing spare shows in
// its slot and covers it for the student. One row per (assignment, slot).

import Core
import Fluent
import Vapor

final class APICompositeSpare: Model, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "composite_spares"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "assignment_id")
    var assignmentID: UUID

    /// The student the spare credits.
    @Field(key: "user_id")
    var userID: UUID

    @Field(key: "slot")
    var slot: Int

    /// The `compositeSpare` submission that renders this slot.
    @Field(key: "submission_id")
    var submissionID: String

    /// Standard padded base64 of the pixels; nil until the job reports a
    /// valid contribution.
    @OptionalField(key: "data")
    var data: String?

    /// Whether the student's code passed the slot's test. Only a passing
    /// spare is shown.
    @Field(key: "passed")
    var passed: Bool

    /// Set when the job's result is recorded. Until then the spare is
    /// grading, and its slot is taken.
    @Field(key: "finished")
    var finished: Bool

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(assignmentID: UUID, userID: UUID, slot: Int, submissionID: String) {
        self.assignmentID = assignmentID
        self.userID = userID
        self.slot = slot
        self.submissionID = submissionID
        self.data = nil
        self.passed = false
        self.finished = false
    }
}
