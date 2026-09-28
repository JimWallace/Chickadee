// APIServer/Models/APIMatchResult.swift
//
// One row per (submission, opponent) match in a class activity
// (docs/class-activities.md). Opened at CLAIM, when the job is built and the
// opponent chosen, and completed at INGEST, when the result lands: that is
// how the result path knows which opponent the job actually played, without
// the worker echoing it back and without a column on `submissions`.
//
// The unique key on (submission_id, opponent_identity) is what makes ingest
// idempotent: a replayed report finds its row already completed and does
// nothing, and a re-test reopens the same row rather than adding one.

import Fluent
import Vapor

final class APIMatchResult: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "match_results"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "test_setup_id")
    var testSetupID: String

    /// The challenger — the submission the job graded.
    @Field(key: "submission_id")
    var submissionID: String

    /// The opponent's submission when the opponent was one (a champion, later
    /// a classmate); nil for a bundled bot or an empty hill.
    @OptionalField(key: "opponent_submission_id")
    var opponentSubmissionID: String?

    /// The opponent's identity as `JobOpponent` spells it for the seed:
    /// `submission:<id>`, `supportFile:<name>` or `none`. Never nil, so the
    /// unique key holds for a bot opponent too.
    @Field(key: "opponent_identity")
    var opponentIdentity: String

    /// Slice 5's bracket round; nil until then.
    @OptionalField(key: "round")
    var round: Int?

    /// The match entry's credit and ranking number, once completed.
    @OptionalField(key: "score")
    var score: Double?

    @OptionalField(key: "metric")
    var metric: Double?

    /// Whether the challenger won — the match entry passed. Nil until the
    /// result lands.
    @OptionalField(key: "won")
    var won: Bool?

    /// The seed the job carried, so a replay can be reproduced by hand.
    @Field(key: "seed")
    var seed: String

    @Timestamp(key: "created_at", on: .none)
    var createdAt: Date?

    /// Nil while the job is out; set when the result lands. A completed row
    /// is never completed again.
    @Timestamp(key: "completed_at", on: .none)
    var completedAt: Date?

    init() {}

    init(
        testSetupID: String, submissionID: String, opponentSubmissionID: String?,
        opponentIdentity: String, seed: String, createdAt: Date
    ) {
        self.testSetupID = testSetupID
        self.submissionID = submissionID
        self.opponentSubmissionID = opponentSubmissionID
        self.opponentIdentity = opponentIdentity
        self.seed = seed
        self.createdAt = createdAt
    }
}
