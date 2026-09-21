// APIServer/Migrations/CreateTournamentRuns.swift
//
// A tournament's frozen entrants and its rounds (docs/class-activities.md).
// Additive; the slots cascade with their run.

import Fluent

struct CreateTournamentRuns: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("tournament_runs")
            .id()
            .field("test_setup_id", .string, .required)
            .field("schedule", .string, .required)
            .field("started_by", .uuid)
            .field("started_at", .datetime, .required)
            .field("entrants", .string, .required)
            .field("status", .string, .required)
            .field("current_round", .int, .required)
            .field("round_count", .int, .required)
            .field("winner_user_id", .uuid)
            .field("completed_at", .datetime)
            .create()
        try await database.schema("tournament_matches")
            .id()
            .field(
                "tournament_id",
                .uuid,
                .required,
                .references("tournament_runs", "id", onDelete: .cascade)
            )
            .field("round", .int, .required)
            .field("position", .int, .required)
            .field("home_seed", .int, .required)
            .field("away_seed", .int)
            .field("match_submission_id", .string)
            .field("winner_seed", .int)
            .field("completed_at", .datetime)
            .unique(on: "tournament_id", "round", "position")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("tournament_matches").delete()
        try await database.schema("tournament_runs").delete()
    }
}
