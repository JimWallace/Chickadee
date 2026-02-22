import Fluent
import SQLKit

struct AddValidationToAssignments: AsyncMigration {
    func prepare(on database: Database) async throws {
        let existing = try await existingColumns(on: database)

        if !existing.contains("validation_status") {
            try await database.schema("assignments")
                .field("validation_status", .string)
                .update()
        }

        if !existing.contains("validation_submission_id") {
            try await database.schema("assignments")
                .field("validation_submission_id", .string)
                .update()
        }
    }

    func revert(on database: Database) async throws {
        let existing = try await existingColumns(on: database)

        if existing.contains("validation_submission_id") {
            try await database.schema("assignments")
                .deleteField("validation_submission_id")
                .update()
        }
        if existing.contains("validation_status") {
            try await database.schema("assignments")
                .deleteField("validation_status")
                .update()
        }
    }

    private func existingColumns(on database: Database) async throws -> Set<String> {
        guard let sql = database as? SQLDatabase else {
            return []
        }

        let rows = try await sql.raw("PRAGMA table_info(assignments)").all()
        var names: Set<String> = []
        names.reserveCapacity(rows.count)
        for row in rows {
            if let name = try? row.decode(column: "name", as: String.self) {
                names.insert(name)
            }
        }
        return names
    }
}
