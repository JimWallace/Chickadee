// APIServer/Models/APIActivityStanding.swift
//
// One row per (assignment, student) in a round robin's standings
// (docs/class-activities.md): the matches their LATEST submission played,
// won, drew and lost, and its average match score. Recomputed at ingest from
// that submission's completed `match_results` rows — never best-so-far, since
// a resubmission replaces the row — and read by the leaderboard page, the
// staff standings panel and the `standing` / `matchesWon` badge signals.

import Fluent
import Vapor

final class APIActivityStanding: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "activity_standings"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "test_setup_id")
    var testSetupID: String

    @Field(key: "user_id")
    var userID: UUID

    /// The submission the row was computed from — the student's latest.
    @Field(key: "submission_id")
    var submissionID: String

    @Field(key: "played")
    var played: Int

    @Field(key: "wins")
    var wins: Int

    @Field(key: "draws")
    var draws: Int

    @Field(key: "losses")
    var losses: Int

    /// The sum of the match entry's `score` over the matches played, so the
    /// average is `scoreSum / played`.
    @Field(key: "score_sum")
    var scoreSum: Double

    @Timestamp(key: "updated_at", on: .none)
    var updatedAt: Date?

    init() {}

    init(
        testSetupID: String, userID: UUID, submissionID: String,
        played: Int, wins: Int, draws: Int, losses: Int, scoreSum: Double, updatedAt: Date
    ) {
        self.testSetupID = testSetupID
        self.userID = userID
        self.submissionID = submissionID
        self.played = played
        self.wins = wins
        self.draws = draws
        self.losses = losses
        self.scoreSum = scoreSum
        self.updatedAt = updatedAt
    }

    /// The ranking key: average match score, then wins, then matches played.
    var averageScore: Double { played > 0 ? scoreSum / Double(played) : 0 }
}
