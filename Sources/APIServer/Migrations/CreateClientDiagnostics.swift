import Fluent
import SQLKit

struct CreateClientDiagnostics: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("client_diagnostics")
            .id()
            .field(
                "user_id",
                .uuid,
                .required,
                .references("users", "id", onDelete: .cascade)
            )
            .field(
                "test_setup_id",
                .string,
                .references("test_setups", "id", onDelete: .setNull)
            )
            .field("kind", .string, .required)
            .field("failed_checks", .string)
            .field("user_agent", .string)
            .field("created_at", .datetime, .required)
            .create()

        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_client_diagnostics_setup_created ON client_diagnostics(test_setup_id, created_at)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_client_diagnostics_setup_created").run()
        }
        try await database.schema("client_diagnostics").delete()
    }
}
