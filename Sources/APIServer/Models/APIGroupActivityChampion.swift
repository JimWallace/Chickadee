// APIServer/Models/APIGroupActivityChampion.swift
//
// Who holds one lab group's hill in a king-of-the-hill activity that runs
// once per group (docs/lab-groups.md, slice 3b). The per-group twin of
// `APIActivityChampion`: one row per (assignment, group), so each lab has its
// own hill and a course-wide champion from before the activity ran per group
// holds none of them. Written at ingest by `recordActivityMatch`, never in a
// sweep. Rows go with their student.

import Fluent
import Foundation

final class APIGroupActivityChampion: Model, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "group_activity_champions"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "test_setup_id")
    var testSetupID: String

    /// The lab group whose hill this is.
    @Field(key: "group_id")
    var groupID: UUID

    @Field(key: "user_id")
    var userID: UUID

    /// The submission that holds the hill, as on `APIActivityChampion`.
    @Field(key: "submission_id")
    var submissionID: String

    @Timestamp(key: "crowned_at", on: .none)
    var crownedAt: Date?

    @Field(key: "defences")
    var defences: Int

    init() {}

    init(testSetupID: String, groupID: UUID, userID: UUID, submissionID: String, crownedAt: Date) {
        self.testSetupID = testSetupID
        self.groupID = groupID
        self.userID = userID
        self.submissionID = submissionID
        self.crownedAt = crownedAt
        self.defences = 0
    }
}
