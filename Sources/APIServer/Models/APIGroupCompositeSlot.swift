// APIServer/Models/APIGroupCompositeSlot.swift
//
// One dealt slot of a class composite that runs once per lab group
// (docs/lab-groups.md, slice 4): the per-group twin of `APICompositeSlot`.
// Each group deals its own slots, so two groups hold the same slot numbers.
// A student still holds one slot per assignment. Two unique keys make
// dealing safe under a race: one row per (assignment, student), and one
// student per (assignment, group, round, slot). Rows follow their assignment
// and their student on delete.

import Fluent
import Foundation

final class APIGroupCompositeSlot: Model, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "group_composite_slots"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "assignment_id")
    var assignmentID: UUID

    /// The lab group whose session the slot was dealt in.
    @Field(key: "group_id")
    var groupID: UUID

    @Field(key: "user_id")
    var userID: UUID

    @Field(key: "slot")
    var slot: Int

    @Field(key: "round")
    var round: Int

    @Timestamp(key: "dealt_at", on: .create)
    var dealtAt: Date?

    init() {}

    init(assignmentID: UUID, groupID: UUID, userID: UUID, slot: Int, round: Int) {
        self.assignmentID = assignmentID
        self.groupID = groupID
        self.userID = userID
        self.slot = slot
        self.round = round
    }
}
