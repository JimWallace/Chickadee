// APIServer/Models/APICompositeSlot.swift
//
// One dealt slot of a class composite (docs/class-composite.md, slice 3): the
// part of the shared image one student renders. A slot does not change after
// it is dealt. Two unique keys make dealing safe under a race: one row per
// (assignment, student), and one student per (assignment, round, slot). Rows
// follow their assignment and their student on delete.

import Fluent
import Vapor

final class APICompositeSlot: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "composite_slots"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "assignment_id")
    var assignmentID: UUID

    @Field(key: "user_id")
    var userID: UUID

    /// The slot index, `0..<layout.slotCount`.
    @Field(key: "slot")
    var slot: Int

    /// 0 for the first pass through the deal sequence, 1 for the second (more
    /// students than slots), and so on.
    @Field(key: "round")
    var round: Int

    @Timestamp(key: "dealt_at", on: .create)
    var dealtAt: Date?

    init() {}

    init(assignmentID: UUID, userID: UUID, slot: Int, round: Int) {
        self.assignmentID = assignmentID
        self.userID = userID
        self.slot = slot
        self.round = round
    }
}
