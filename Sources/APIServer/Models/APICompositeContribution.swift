// APIServer/Models/APICompositeContribution.swift
//
// One student's latest contribution to a class composite
// (docs/class-composite.md, slice 4): the pixels their newest graded
// submission reported for their slot, and whether that test passed. One row per
// (assignment, student). A newer submission replaces the row; an older one,
// re-tested later, does not. Rows follow their assignment, their student and
// their submission on delete.

import Core
import Fluent
import Vapor

final class APICompositeContribution: Model, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "composite_contributions"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "assignment_id")
    var assignmentID: UUID

    /// The lab group whose image the student's slot is in, for a composite
    /// that runs once per group (docs/lab-groups.md, slice 4); nil for the
    /// whole class's image.
    @OptionalField(key: "group_id")
    var groupID: UUID?

    @Field(key: "user_id")
    var userID: UUID

    /// The slot the student held when this contribution was graded.
    @Field(key: "slot")
    var slot: Int

    /// The submission that reported the pixels.
    @Field(key: "submission_id")
    var submissionID: String

    /// When that submission arrived. A contribution replaces this row only
    /// when its submission arrived at the same time or later.
    @Field(key: "submitted_at")
    var submittedAt: Date

    @Field(key: "width")
    var width: Int

    @Field(key: "height")
    var height: Int

    @Field(key: "frames")
    var frames: Int

    /// A `CompositePixelFormat` raw value.
    @Field(key: "format")
    var format: String

    /// Standard padded base64 of the pixels, as the script reported them.
    @Field(key: "data")
    var data: String

    /// Whether the test that reported the contribution passed.
    @Field(key: "passed")
    var passed: Bool

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        assignmentID: UUID, userID: UUID, slot: Int, submissionID: String, submittedAt: Date,
        contribution: CompositeContribution, passed: Bool
    ) {
        self.assignmentID = assignmentID
        self.userID = userID
        self.slot = slot
        self.submissionID = submissionID
        self.submittedAt = submittedAt
        self.width = contribution.width
        self.height = contribution.height
        self.frames = contribution.frames
        self.format = contribution.format.rawValue
        self.data = contribution.data
        self.passed = passed
    }
}
