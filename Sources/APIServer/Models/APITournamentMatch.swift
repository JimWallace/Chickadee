// APIServer/Models/APITournamentMatch.swift
//
// One slot of a tournament bracket or round robin (docs/class-activities.md).

import Core
import Fluent
import Vapor

/// One slot of a tournament round: who plays whom, the match job that plays
/// it (nil for a bye), and the winner once it lands. The bracket structure
/// lives here; the match's score, metric and seed live on the `match_results`
/// row the claim opens for the match job, as for every other match.
final class APITournamentMatch: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "tournament_matches"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "tournament_id")
    var tournamentID: UUID

    @Field(key: "round")
    var round: Int

    @Field(key: "position")
    var position: Int

    @Field(key: "home_seed")
    var homeSeed: Int

    @OptionalField(key: "away_seed")
    var awaySeed: Int?

    /// The `tournamentMatch` submission that plays this slot; nil for a bye.
    @OptionalField(key: "match_submission_id")
    var matchSubmissionID: String?

    @OptionalField(key: "winner_seed")
    var winnerSeed: Int?

    @Timestamp(key: "completed_at", on: .none)
    var completedAt: Date?

    init() {}

    init(tournamentID: UUID, slot: TournamentSlot, matchSubmissionID: String?, completedAt: Date?) {
        self.tournamentID = tournamentID
        self.round = slot.round
        self.position = slot.position
        self.homeSeed = slot.homeSeed
        self.awaySeed = slot.awaySeed
        self.matchSubmissionID = matchSubmissionID
        self.winnerSeed = slot.winnerSeed
        self.completedAt = completedAt
    }

    var slot: TournamentSlot {
        TournamentSlot(round: round, position: position, homeSeed: homeSeed, awaySeed: awaySeed, winnerSeed: winnerSeed)
    }
}
