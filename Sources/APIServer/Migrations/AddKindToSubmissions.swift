import Fluent
import SQLKit

struct AddKindToSubmissions: AsyncMigration {
    func prepare(on database: Database) async throws {
        let existing = try await existingColumns(on: database)
        if !existing.contains("kind") {
            try await database.schema("submissions")
                .field("kind", .string)
                .update()
        }

        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw(
            "UPDATE submissions SET kind = 'student' WHERE kind IS NULL OR kind = ''"
        ).run()
    }

    func revert(on database: Database) async throws {
        let existing = try await existingColumns(on: database)
        if existing.contains("kind") {
            try await database.schema("submissions")
                .deleteField("kind")
                .update()
        }
    }

    private func existingColumns(on database: Database) async throws -> Set<String> {
        guard let sql = database as? SQLDatabase else { return [] }
        let rows = try await sql.raw("PRAGMA table_info(submissions)").all()
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
