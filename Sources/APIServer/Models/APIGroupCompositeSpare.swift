// APIServer/Models/APIGroupCompositeSpare.swift
//
// One spare slot of a class composite that runs once per lab group
// (docs/lab-groups.md, slice 4b): the per-group twin of `APICompositeSpare`.
// Each group fills its own holes, so two groups can hold a spare in the same
// slot. One row per (assignment, group, slot).

import Fluent
import Foundation

final class APIGroupCompositeSpare: Model, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "group_composite_spares"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "assignment_id")
    var assignmentID: UUID

    /// The lab group whose image the spare fills.
    @Field(key: "group_id")
    var groupID: UUID

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

    init(assignmentID: UUID, groupID: UUID, userID: UUID, slot: Int, submissionID: String) {
        self.assignmentID = assignmentID
        self.groupID = groupID
        self.userID = userID
        self.slot = slot
        self.submissionID = submissionID
        self.data = nil
        self.passed = false
        self.finished = false
    }
}
