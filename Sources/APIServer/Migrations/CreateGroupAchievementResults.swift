// APIServer/Migrations/CreateGroupAchievementResults.swift
//
// `group_achievement_results`: each lab group's snapshot of a class goal
// (docs/lab-groups.md, slice 5), one row per (test setup, group,
// achievement). No foreign key to the group: a group is removed by
// `removed_at`, never by a delete.

import Fluent

struct CreateGroupAchievementResults: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(APIGroupAchievementResult.schema)
            .id()
            .field("test_setup_id", .string, .required)
            .field("group_id", .uuid, .required)
            .field("achievement_id", .string, .required)
            .field("students_meeting", .int, .required)
            .field("denominator", .int, .required)
            .field("progress", .double, .required)
            .field("items_covered", .int)
            .field("items_required", .int)
            .field("coverage_percent", .double)
            .field("coverage_required", .double)
            .field("locked", .bool, .required)
            .field("evaluated_at", .datetime, .required)
            .unique(on: "test_setup_id", "group_id", "achievement_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(APIGroupAchievementResult.schema).delete()
    }
}
