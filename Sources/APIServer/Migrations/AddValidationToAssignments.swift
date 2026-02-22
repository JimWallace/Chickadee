import Fluent

struct AddValidationToAssignments: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("assignments")
            .field("validation_status", .string)
            .field("validation_submission_id", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("assignments")
            .deleteField("validation_submission_id")
            .deleteField("validation_status")
            .update()
    }
}
