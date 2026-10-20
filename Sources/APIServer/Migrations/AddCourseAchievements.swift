// APIServer/Migrations/AddCourseAchievements.swift
//
// `courses.achievements`: the course achievements as a JSON list
// (docs/achievement-rewards.md, decision 6, slice S3). Optional: nil is no
// course achievements, which is every course made before the column.

import Fluent

struct AddCourseAchievements: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(APICourse.schema)
            .field("achievements", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(APICourse.schema)
            .deleteField("achievements")
            .update()
    }
}
