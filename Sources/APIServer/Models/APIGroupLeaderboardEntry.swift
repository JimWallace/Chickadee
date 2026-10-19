// APIServer/Models/APIGroupLeaderboardEntry.swift
//
// One student's best `metric` in one lab group's run of a leaderboard
// activity that runs once per group (docs/lab-groups.md, slice 3a). The
// per-group twin of `APILeaderboardEntry`: one row per (assignment, group,
// student), so a student who plays in two labs ranks in each, and a row from
// before the activity ran per group blocks nothing. Written at ingest by
// `recordLeaderboardEntry`, never in a sweep. Rows go with their student.

import Fluent
import Foundation

final class APIGroupLeaderboardEntry: Model, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "group_leaderboard_entries"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "test_setup_id")
    var testSetupID: String

    /// The lab group whose session the result was played in.
    @Field(key: "group_id")
    var groupID: UUID

    @Field(key: "user_id")
    var userID: UUID

    /// The submission that reported the best metric in this group.
    @Field(key: "submission_id")
    var submissionID: String

    @Field(key: "metric")
    var metric: Double

    /// When the best metric was reached; ties rank the earlier row first.
    @Timestamp(key: "reached_at", on: .none)
    var reachedAt: Date?

    init() {}

    init(testSetupID: String, groupID: UUID, userID: UUID, submissionID: String, metric: Double, reachedAt: Date) {
        self.testSetupID = testSetupID
        self.groupID = groupID
        self.userID = userID
        self.submissionID = submissionID
        self.metric = metric
        self.reachedAt = reachedAt
    }
}
