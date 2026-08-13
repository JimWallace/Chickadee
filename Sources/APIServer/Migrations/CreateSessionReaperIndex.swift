import Fluent
import SQLKit

/// Index for the hourly session reaper's sweep column.
///
/// `AddSessionsCreatedAt` gave `_fluent_sessions` a `created_at` column so
/// `SessionReaperService` could expire sessions, but left it unindexed. That
/// sweep runs every hour as `DELETE … WHERE created_at < cutoff` against the
/// table with the highest read volume in the schema — every authenticated
/// request resolves its session through it — so the reaper was scanning and
/// locking the hottest table on the server once an hour (#1365).
struct CreateSessionReaperIndex: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_fluent_sessions_created_at ON _fluent_sessions(created_at)"
        ).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        try await sql.raw("DROP INDEX IF EXISTS idx_fluent_sessions_created_at").run()
    }
}
