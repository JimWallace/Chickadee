// APIServer/Models/APIGroupClassItemCoverage.swift
//
// One item a lab group covered, for an activity that runs once per lab group
// (docs/lab-groups.md, slice 5b): the per-group twin of
// `APIClassItemCoverage`. Every lab covers the same items, so one row per
// (test setup, group, item), attributed to the submission that covered it
// first in that lab. A twin table, because `class_item_coverage` is unique on
// (test setup, item) and SQLite cannot drop that key.

import Fluent
import Foundation

final class APIGroupClassItemCoverage: Model, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "group_class_item_coverage"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "test_setup_id")
    var testSetupID: String

    /// The lab group whose coverage this is.
    @Field(key: "group_id")
    var groupID: UUID

    @Field(key: "item")
    var item: String

    /// The student whose submission covered it first in the lab.
    @Field(key: "user_id")
    var userID: UUID

    @Field(key: "submission_id")
    var submissionID: String

    @Timestamp(key: "covered_at", on: .create)
    var coveredAt: Date?

    init() {}

    init(testSetupID: String, groupID: UUID, item: String, userID: UUID, submissionID: String) {
        self.testSetupID = testSetupID
        self.groupID = groupID
        self.item = item
        self.userID = userID
        self.submissionID = submissionID
    }
}
