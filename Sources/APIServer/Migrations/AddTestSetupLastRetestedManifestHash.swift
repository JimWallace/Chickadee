// APIServer/Migrations/AddTestSetupLastRetestedManifestHash.swift
//
// CONSOLIDATED.  `last_retested_manifest_hash` is folded into
// CreateTestSetups as of v0.4.171.  Struct name preserved so existing
// prod's `_fluent_migrations` tracking is undisturbed; no-op on fresh
// deploys.

import Fluent

struct AddTestSetupLastRetestedManifestHash: AsyncMigration {
    func prepare(on database: Database) async throws {
        // No-op: see CreateTestSetups.swift.
    }

    func revert(on database: Database) async throws {
        // No-op.
    }
}
