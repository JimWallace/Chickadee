// APIServer/Models/APILeaderboardEntry.swift
//
// One row per (assignment, student): the best ranking `metric` any of the
// student's submissions has reported, and which submission reported it.
//
// This is the materialised leaderboard behind a class activity
// (docs/class-activities.md). The per-outcome metrics it is derived from
// already sit in `result_collections`, so nothing here is new information;
// what is new is that the ranking is cheap to read — a leaderboard page must
// not decode every submission's collection to sort a class.
//
// WRITTEN AT INGEST, NEVER IN THE SWEEP — the `class_item_coverage` pattern.
// The class-goal sweep is blob-free by design (#1160), and a leaderboard
// recomputed from stored collections every five minutes would undo that.
//
// BEST-SO-FAR, ENFORCED BY THE UPSERT. The unique constraint on
// (test_setup_id, user_id) is what makes this monotone and idempotent rather
// than merely intended: a re-test, a replayed report, or a later submission
// that scored worse all leave the row where it was. Higher is better —
// `RecordDimension.highestMetric` — so a script measuring something where
// lower wins reports its negation.

import Fluent
import Vapor

final class APILeaderboardEntry: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "leaderboard_entries"

    @ID(key: .id)
    var id: UUID?

    /// The assignment this ranking belongs to.
    @Field(key: "test_setup_id")
    var testSetupID: String

    /// The student ranked.
    @Field(key: "user_id")
    var userID: UUID

    /// The submission that reported the best metric. Attribution is what makes
    /// a row auditable — staff can open the run behind a rank.
    @Field(key: "submission_id")
    var submissionID: String

    /// The best `metric` any of this student's submissions reported.
    @Field(key: "metric")
    var metric: Double

    /// When the best metric was reached. Ties on `metric` rank the earlier
    /// row first, so this is the tie-break the page sorts on.
    @Timestamp(key: "reached_at", on: .none)
    var reachedAt: Date?

    init() {}

    init(testSetupID: String, userID: UUID, submissionID: String, metric: Double, reachedAt: Date) {
        self.testSetupID = testSetupID
        self.userID = userID
        self.submissionID = submissionID
        self.metric = metric
        self.reachedAt = reachedAt
    }
}
