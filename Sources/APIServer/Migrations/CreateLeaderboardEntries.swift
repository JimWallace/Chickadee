// APIServer/Migrations/CreateLeaderboardEntries.swift
//
// The materialised leaderboard behind a class activity: one row per
// (assignment, student) holding the best ranking metric any of their
// submissions reported. Written at result ingest (`recordLeaderboardEntry`),
// read by the leaderboard page. The unique constraint is what makes the
// best-so-far upsert idempotent under re-tests and replayed reports.
// Cascade-deletes follow the parent user.

import Fluent

struct CreateLeaderboardEntries: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("leaderboard_entries")
            .id()
            .field("test_setup_id", .string, .required)
            .field(
                "user_id",
                .uuid,
                .required,
                .references("users", "id", onDelete: .cascade)
            )
            .field("submission_id", .string, .required)
            .field("metric", .double, .required)
            .field("reached_at", .datetime, .required)
            .unique(on: "test_setup_id", "user_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("leaderboard_entries").delete()
    }
}
