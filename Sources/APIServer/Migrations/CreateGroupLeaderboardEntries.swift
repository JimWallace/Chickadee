// APIServer/Migrations/CreateGroupLeaderboardEntries.swift
//
// `group_leaderboard_entries`: a per-group leaderboard activity's best rows,
// one per (assignment, group, student) (docs/lab-groups.md, slice 3a). Rows go
// with their student. No foreign key to the group: a group is removed by
// `removed_at`, never by a delete.

import Fluent

struct CreateGroupLeaderboardEntries: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(APIGroupLeaderboardEntry.schema)
            .id()
            .field("test_setup_id", .string, .required)
            .field("group_id", .uuid, .required)
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("submission_id", .string, .required)
            .field("metric", .double, .required)
            .field("reached_at", .datetime, .required)
            .unique(on: "test_setup_id", "group_id", "user_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(APIGroupLeaderboardEntry.schema).delete()
    }
}
