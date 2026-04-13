// APIServer/Migrations/CreateClassAchievements.swift

import Fluent

struct CreateClassAchievements: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("class_achievements")
            .id()
            .field("test_setup_id",  .string, .required)
            .field("achievement_id", .string, .required)
            .field("user_id",        .uuid,   .required)
            .field("submission_id",  .string, .required)
            .field("metric_value",   .double)
            .field("awarded_at",     .datetime)
            // One winner per badge per assignment.
            .unique(on: "test_setup_id", "achievement_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("class_achievements").delete()
    }
}
