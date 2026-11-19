// APIServer/Migrations/CreateActivityStandings.swift
//
// A round robin's standings (docs/class-activities.md): one row per
// (assignment, student), recomputed at ingest from the student's latest
// submission's match rows. Additive; cascade-deletes follow the user.

import Fluent

struct CreateActivityStandings: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("activity_standings")
            .id()
            .field("test_setup_id", .string, .required)
            .field(
                "user_id",
                .uuid,
                .required,
                .references("users", "id", onDelete: .cascade)
            )
            .field("submission_id", .string, .required)
            .field("played", .int, .required)
            .field("wins", .int, .required)
            .field("draws", .int, .required)
            .field("losses", .int, .required)
            .field("score_sum", .double, .required)
            .field("updated_at", .datetime, .required)
            // Folded from AddActivityStandingGroup: the lab group of the
            // session the row's submission was made in (docs/lab-groups.md,
            // slice 3c). Nil is course-wide. No foreign key.
            .field("group_id", .uuid)
            .unique(on: "test_setup_id", "user_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("activity_standings").delete()
    }
}
