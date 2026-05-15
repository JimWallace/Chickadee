// APIServer/Migrations/AddSubmissionRetestedAt.swift
//
// CONSOLIDATED.  `retested_at` is folded into CreateSubmissions as of
// v0.4.171.  Struct name preserved so existing prod's
// `_fluent_migrations` tracking is undisturbed; no-op on fresh deploys.

import Fluent

struct AddSubmissionRetestedAt: AsyncMigration {
    func prepare(on database: Database) async throws {
        // No-op: see CreateSubmissions.swift.
    }

    func revert(on database: Database) async throws {
        // No-op.
    }
}
