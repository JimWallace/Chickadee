import Fluent

struct AddAssignmentDeadlineOverrideActive: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("assignments")
            .field("deadline_override_active", .bool)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("assignments")
            .deleteField("deadline_override_active")
            .update()
    }
}
