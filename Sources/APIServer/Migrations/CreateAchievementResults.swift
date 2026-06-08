// APIServer/Migrations/CreateAchievementResults.swift

import Fluent

struct CreateAchievementResults: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("achievement_results")
            .id()
            .field("test_setup_id", .string, .required)
            .field("achievement_id", .string, .required)
            .field("students_meeting", .int, .required)
            .field("denominator", .int, .required)
            .field("progress", .double, .required)
            .field("locked", .bool, .required)
            .field("evaluated_at", .datetime, .required)
            // One snapshot per achievement per assignment.
            .unique(on: "test_setup_id", "achievement_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("achievement_results").delete()
    }
}
