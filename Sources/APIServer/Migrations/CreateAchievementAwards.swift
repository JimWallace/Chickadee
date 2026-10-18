// APIServer/Migrations/CreateAchievementAwards.swift
//
// `achievement_awards`: one row per achievement a student has earned
// (APIAchievementAward, docs/achievement-rewards.md, decision 2). The rows go
// with the user. The unique index stores an award once when two page loads
// write it at the same time.

import Fluent

struct CreateAchievementAwards: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(APIAchievementAward.schema)
            .id()
            .field(
                "user_id", .uuid, .required,
                .references("users", "id", onDelete: .cascade)
            )
            .field("level", .string, .required)
            .field("owner_id", .string, .required)
            .field("achievement_id", .string, .required)
            .field("submission_id", .string)
            .field("label", .string, .required)
            .field("detail", .string)
            .field("earned_at", .datetime)
            .unique(on: "user_id", "level", "owner_id", "achievement_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(APIAchievementAward.schema).delete()
    }
}
