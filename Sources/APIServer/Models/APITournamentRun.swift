// APIServer/Models/APITournamentRun.swift
//
// One tournament (docs/class-activities.md, "Tournaments"): the frozen
// entrants, the schedule, which round is out, and the winner once the last
// round lands. Started by an instructor action; advanced at result ingest,
// never in the sweep. An assignment keeps every run — starting another
// supersedes the running one, so a stalled run can never block a class.

import Core
import Fluent
import Vapor

final class APITournamentRun: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "tournament_runs"

    enum Status {
        static let running = "running"
        static let complete = "complete"
        static let superseded = "superseded"
    }

    @ID(key: .id)
    var id: UUID?

    @Field(key: "test_setup_id")
    var testSetupID: String

    /// `TournamentSchedule` raw value.
    @Field(key: "schedule")
    var schedule: String

    @OptionalField(key: "started_by")
    var startedBy: UUID?

    @Timestamp(key: "started_at", on: .none)
    var startedAt: Date?

    /// The entrants as `[TournamentEntrant]` JSON, frozen at start: a
    /// student who resubmits afterwards plays with the snapshotted entry.
    @Field(key: "entrants")
    var entrantsJSON: String

    @Field(key: "status")
    var status: String

    /// The round whose matches are out (1-based); the last round once complete.
    @Field(key: "current_round")
    var currentRound: Int

    @Field(key: "round_count")
    var roundCount: Int

    @OptionalField(key: "winner_user_id")
    var winnerUserID: UUID?

    @Timestamp(key: "completed_at", on: .none)
    var completedAt: Date?

    init() {}

    init(
        testSetupID: String, schedule: TournamentSchedule, startedBy: UUID?, startedAt: Date,
        entrants: [TournamentEntrant]
    ) throws {
        self.testSetupID = testSetupID
        self.schedule = schedule.rawValue
        self.startedBy = startedBy
        self.startedAt = startedAt
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.entrantsJSON = String(bytes: try encoder.encode(entrants), encoding: .utf8) ?? "[]"
        self.status = Status.running
        self.currentRound = 1
        self.roundCount = schedule.roundCount(entrantCount: entrants.count)
    }

    var entrants: [TournamentEntrant] {
        (try? JSONDecoder().decode([TournamentEntrant].self, from: Data(entrantsJSON.utf8))) ?? []
    }

    var tournamentSchedule: TournamentSchedule? { TournamentSchedule(rawValue: schedule) }
}
