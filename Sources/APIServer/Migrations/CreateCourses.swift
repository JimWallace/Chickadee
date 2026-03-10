// APIServer/Migrations/CreateCourses.swift

import Fluent

struct CreateCourses: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("courses")
            .id()
            .field("code",        .string, .required)
            .unique(on: "code")
            .field("name",        .string, .required)
            .field("is_archived", .bool,   .required)
            .field("created_at",  .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("courses").delete()
    }
}
