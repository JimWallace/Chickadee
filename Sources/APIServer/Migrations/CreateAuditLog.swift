import Fluent
import SQLKit

struct CreateAuditLog: ChickadeeMigration {
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
            // Folded from AddAuditLogCourseID (#421): first-class course scope
            // for the per-course activity view. Nullable by design — most
            // events (logins, user deletion, secret rotation) belong to no
            // course. The historical migration's Swift-side backfill copied
            // metadata.course_id into the column for pre-existing rows; a
            // fresh table has none, so the fold dropped it.
            .field("course_id", .uuid)
            .field("created_at", .datetime, .required)
            .create()

        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_audit_log_created_at ON audit_log(created_at DESC)"
            ).run()
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_audit_log_action_created ON audit_log(action, created_at DESC)"
            ).run()
            // Folded from AddAuditLogCourseID: the per-course activity view's
            // "every event for this course, newest first" query path.
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_audit_log_course_created ON audit_log(course_id, created_at DESC)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_audit_log_course_created").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_audit_log_action_created").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_audit_log_created_at").run()
        }
        try await database.schema("audit_log").delete()
    }
}
