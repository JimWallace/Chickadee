// APIServer/Migrations/AddUserLastSeenAt.swift

import Fluent

/// Adds `last_seen_at` to the users table.
/// Refreshed on every authenticated request (debounced) so the instructor
/// and admin dashboards show real activity, not a stale `last_login_at`
/// frozen at the moment the cookie session was first established.
struct AddUserLastSeenAt: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("users")
            .field("last_seen_at", .datetime)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("users")
            .deleteField("last_seen_at")
            .update()
    }
}
