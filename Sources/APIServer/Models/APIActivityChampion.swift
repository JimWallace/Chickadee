// APIServer/Models/APIActivityChampion.swift
//
// Who holds the hill in a king-of-the-hill activity (docs/class-activities.md):
// one row per assignment naming the current champion's submission, when they
// took the hill, and how many challengers they have turned back since.
//
// WRITTEN AT INGEST, NEVER IN THE SWEEP — the `leaderboard_entries` pattern.
// The row is the whole state a match job needs: the claim path reads it to
// choose the opponent, and the result path rewrites it when a challenger
// wins. No row means the bundled bot holds the hill (or nobody does).

import Fluent
import Vapor

final class APIActivityChampion: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "activity_champions"

    @ID(key: .id)
    var id: UUID?

    /// The assignment whose hill this is. Unique: one champion at a time.
    @Field(key: "test_setup_id")
    var testSetupID: String

    /// The student holding the hill.
    @Field(key: "user_id")
    var userID: UUID

    /// The submission that holds it — what a challenger's job stages as the
    /// opponent. A champion who resubmits and beats their own earlier entry
    /// moves this forward without losing the hill.
    @Field(key: "submission_id")
    var submissionID: String

    /// When this student took the hill (not when they last upgraded).
    @Timestamp(key: "crowned_at", on: .none)
    var crownedAt: Date?

    /// Challengers turned back since `crownedAt` — the streak the leaderboard
    /// shows. Counted once per challenging submission, through the match row.
    @Field(key: "defences")
    var defences: Int

    init() {}

    init(testSetupID: String, userID: UUID, submissionID: String, crownedAt: Date, defences: Int = 0) {
        self.testSetupID = testSetupID
        self.userID = userID
        self.submissionID = submissionID
        self.crownedAt = crownedAt
        self.defences = defences
    }
}
