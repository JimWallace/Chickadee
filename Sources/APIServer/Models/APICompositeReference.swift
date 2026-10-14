// APIServer/Models/APICompositeReference.swift
//
// One slot of a class composite's reference render (docs/class-composite.md,
// slice 6): the reference solution's output for that slot. "Prepare
// reference" queues one grading job for each slot, and its result fills the
// row. With `emptySlots: reference`, the projector shows the render, dimmed,
// in a slot that has no passing contribution. One row per (assignment, slot).

import Core
import Fluent
import Vapor

final class APICompositeReference: Model, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "composite_references"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "assignment_id")
    var assignmentID: UUID

    @Field(key: "slot")
    var slot: Int

    /// The `compositeReference` submission that renders this slot.
    @Field(key: "submission_id")
    var submissionID: String

    /// Standard padded base64 of the render's pixels; nil until its job
    /// reports a valid contribution.
    @OptionalField(key: "data")
    var data: String?

    /// Whether the reference solution passed the slot's test. Only a passing
    /// render is shown.
    @Field(key: "passed")
    var passed: Bool

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(assignmentID: UUID, slot: Int, submissionID: String) {
        self.assignmentID = assignmentID
        self.slot = slot
        self.submissionID = submissionID
        self.data = nil
        self.passed = false
    }
}
