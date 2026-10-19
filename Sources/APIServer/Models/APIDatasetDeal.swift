// APIServer/Models/APIDatasetDeal.swift
//
// One student's deal number in one assignment, for the partition datasets
// (docs/datasets-course-library.md §4.11). The part of a partitioned file the
// student receives is the number modulo the spec's part count. A number does
// not change after it is dealt. (On a class composite the student's slot is
// the number instead, and no row here is used.) Two unique keys make dealing safe under a
// race: one row per (assignment, student), and one student per (assignment,
// number). Rows follow their assignment and their student on delete.

import Fluent
import Vapor

final class APIDatasetDeal: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "dataset_deals"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "assignment_id")
    var assignmentID: UUID

    @Field(key: "user_id")
    var userID: UUID

    /// The deal number, from 0 up. A number freed by a deleted student is
    /// dealt again.
    @Field(key: "deal_number")
    var dealNumber: Int

    @Timestamp(key: "dealt_at", on: .create)
    var dealtAt: Date?

    init() {}

    init(assignmentID: UUID, userID: UUID, dealNumber: Int) {
        self.assignmentID = assignmentID
        self.userID = userID
        self.dealNumber = dealNumber
    }
}
