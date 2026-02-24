import Fluent
import SQLKit

struct AddSortOrderToAssignments: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("assignments")
            .field("sort_order", .int)
            .update()

        // Backfill existing assignments in creation order to keep stable UI ordering.
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                """
                WITH ordered AS (
                    SELECT id, ROW_NUMBER() OVER (ORDER BY created_at ASC, id ASC) AS rn
                    FROM assignments
                )
                UPDATE assignments
                SET sort_order = (SELECT rn FROM ordered WHERE ordered.id = assignments.id)
                WHERE sort_order IS NULL
                """
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema("assignments")
            .deleteField("sort_order")
            .update()
    }
}
