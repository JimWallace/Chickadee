// APIServer/Migrations/AddUserLastSeenAt.swift
//
// CONSOLIDATED.  `last_seen_at` is folded into CreateUsers as of
// v0.4.171.  Struct name preserved so existing prod's
// `_fluent_migrations` tracking is undisturbed; no-op on fresh deploys.

import Fluent

struct AddUserLastSeenAt: AsyncMigration {
    func prepare(on database: Database) async throws {
        // No-op: see CreateUsers.swift.
    }

    func revert(on database: Database) async throws {
        // No-op.
    }
}
