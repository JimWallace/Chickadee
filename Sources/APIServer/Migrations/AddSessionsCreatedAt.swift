import Fluent
import SQLKit

/// Adds a `created_at` column to Vapor's `_fluent_sessions` table so the
/// session reaper has something to age rows out by.  The Fluent sessions
/// driver only writes `id`, `key`, and `data` — without a server-side
/// timestamp, expired sessions accumulate indefinitely (no Vapor-side TTL).
///
/// The column is added with `DEFAULT CURRENT_TIMESTAMP` so new rows inserted
/// by Vapor's untouched `SessionRecord` model still pick up a timestamp.
/// Pre-existing rows get NULL and are ignored by the reaper — they roll out
/// naturally as Vapor rewrites session rows on login.
///
/// `TIMESTAMP DEFAULT CURRENT_TIMESTAMP` is portable to both PostgreSQL and
/// SQLite (SQLite treats TIMESTAMP as a NUMERIC-affinity TEXT column).
struct AddSessionsCreatedAt: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw(
            "ALTER TABLE _fluent_sessions ADD COLUMN created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP"
        ).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        // Some older SQLite builds don't support DROP COLUMN; best-effort revert.
        try? await sql.raw("ALTER TABLE _fluent_sessions DROP COLUMN created_at").run()
    }
}
