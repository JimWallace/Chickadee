// APIServer/Migrations/AddCourseOpenEnrollment.swift

import Fluent

struct AddCourseOpenEnrollment: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("courses")
            .field("open_enrollment", .bool, .required, .custom("DEFAULT TRUE"))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("courses")
            .deleteField("open_enrollment")
            .update()
    }
}
