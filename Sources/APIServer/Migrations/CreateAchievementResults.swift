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
            // Folded from AddAchievementResultCoverage and
            // AddAchievementResultCoveragePercent (fourth round, #1806): what a
            // union goal (`items_*`) or a corpus goal (`coverage_*`) measured
            // when the snapshot froze. nil on every other goal.
            .field("items_covered", .int)
            .field("items_required", .int)
            .field("coverage_percent", .double)
            .field("coverage_required", .double)
            // One snapshot per achievement per assignment.
            .unique(on: "test_setup_id", "achievement_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("achievement_results").delete()
    }
}
