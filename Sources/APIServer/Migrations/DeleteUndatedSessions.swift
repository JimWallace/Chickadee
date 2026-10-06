// APIServer/Migrations/DeleteUndatedSessions.swift
//
// One-time delete of the `_fluent_sessions` rows that predate the
// `created_at` column (#2281).
//
// `AddSessionsCreatedAt` gave those rows a NULL `created_at`, and nothing
// ever fills it: Vapor's session driver updates only `data`, so the column
// DEFAULT applies to inserts alone. The reaper skips NULL (`created_at <
// cutoff` is never true for it), so these rows would stay in the table that
// every authenticated request reads, for ever. Each one predates the column
// by far more than the reaper's eight-day window, so its session is long
// dead. Every row inserted since takes the DEFAULT, so after this runs no
// undated row can appear again.
//
// Raw SQL, not a model query, so it depends on no model's columns.

import Fluent
import SQLKit

struct DeleteUndatedSessions: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw("DELETE FROM _fluent_sessions WHERE created_at IS NULL").run()
    }

    /// Nothing to restore: the deleted sessions were already dead.
    func revert(on database: Database) async throws {}
}
