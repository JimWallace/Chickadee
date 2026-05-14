import Fluent
import SQLKit

struct CreateAuditLog: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("audit_log")
            .id()
            .field(
                "actor_user_id",
                .uuid,
                .references("users", "id", onDelete: .setNull)
            )
            .field("actor_username", .string)
            .field("action", .string, .required)
            .field("target_type", .string)
            .field("target_id", .string)
            .field("remote_addr", .string)
            .field("user_agent", .string)
            .field("metadata", .string)
            .field("created_at", .datetime, .required)
            .create()

        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_audit_log_created_at ON audit_log(created_at DESC)"
            ).run()
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_audit_log_action_created ON audit_log(action, created_at DESC)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_audit_log_action_created").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_audit_log_created_at").run()
        }
        try await database.schema("audit_log").delete()
    }
}
