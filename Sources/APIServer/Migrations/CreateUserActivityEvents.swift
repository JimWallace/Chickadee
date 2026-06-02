import Fluent
import SQLKit

/// Creates `user_activity_events` — the per-user activity-ping table behind the
/// admin dashboard's "active users over time" chart.  Indexed on `created_at`
/// (the chart scans a trailing window) and on `(created_at, user_id)` (the
/// distinct-users-per-bucket aggregation).
struct CreateUserActivityEvents: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("user_activity_events")
            .id()
            .field(
                "user_id",
                .uuid,
                .required,
                .references("users", "id", onDelete: .cascade)
            )
            .field("role", .string)
            .field("created_at", .datetime, .required)
            .create()

        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_user_activity_events_created ON user_activity_events(created_at)"
            ).run()
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_user_activity_events_created_user ON user_activity_events(created_at, user_id)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_user_activity_events_created").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_user_activity_events_created_user").run()
        }
        try await database.schema("user_activity_events").delete()
    }
}
