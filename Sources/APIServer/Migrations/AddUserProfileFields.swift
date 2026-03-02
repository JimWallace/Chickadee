import Fluent

struct AddUserProfileFields: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("users")
            .field("preferred_name", .string)
            .update()
        try await database.schema("users")
            .field("user_id", .string)
            .update()
        try await database.schema("users")
            .field("student_id", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("users")
            .deleteField("student_id")
            .update()
        try await database.schema("users")
            .deleteField("user_id")
            .update()
        try await database.schema("users")
            .deleteField("preferred_name")
            .update()
    }
}
