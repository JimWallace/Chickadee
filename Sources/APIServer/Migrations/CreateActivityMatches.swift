// APIServer/Migrations/CreateActivityMatches.swift
//
// The two tables behind a king-of-the-hill activity (docs/class-activities.md):
// `match_results`, one row per (submission, opponent) match opened at claim
// and completed at ingest, and `activity_champions`, one row per assignment
// naming who holds the hill. Both additive; cascade-deletes follow the user.

import Fluent

struct CreateActivityMatches: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("match_results")
            .id()
            .field("test_setup_id", .string, .required)
            .field("submission_id", .string, .required)
            .field("opponent_submission_id", .string)
            .field("opponent_identity", .string, .required)
            .field("round", .int)
            .field("score", .double)
            .field("metric", .double)
            .field("won", .bool)
            .field("seed", .string, .required)
            .field("created_at", .datetime, .required)
            .field("completed_at", .datetime)
            .unique(on: "submission_id", "opponent_identity")
            .create()
        try await database.schema("activity_champions")
            .id()
            .field("test_setup_id", .string, .required)
            .field(
                "user_id",
                .uuid,
                .required,
                .references("users", "id", onDelete: .cascade)
            )
            .field("submission_id", .string, .required)
            .field("crowned_at", .datetime, .required)
            .field("defences", .int, .required)
            .unique(on: "test_setup_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("activity_champions").delete()
        try await database.schema("match_results").delete()
    }
}
