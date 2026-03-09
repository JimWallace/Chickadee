// APIServer/Migrations/AddCourses.swift

import Fluent

struct AddCourses: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("courses")
            .id()
            .field("code",        .string, .required)
            .field("name",        .string, .required)
            .field("is_archived", .bool,   .required)
            .field("created_at",  .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("courses").delete()
    }
}
