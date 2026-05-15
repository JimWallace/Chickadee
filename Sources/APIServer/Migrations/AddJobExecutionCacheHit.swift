// APIServer/Migrations/AddJobExecutionCacheHit.swift
//
// CONSOLIDATED.  `test_setup_cache_hit` is folded into
// CreateJobExecutionMetrics as of v0.4.171.  Struct name preserved so
// existing prod's `_fluent_migrations` tracking is undisturbed; no-op
// on fresh deploys.

import Fluent

struct AddJobExecutionCacheHit: AsyncMigration {
    func prepare(on database: Database) async throws {
        // No-op: see CreateJobExecutionMetrics.swift.
    }

    func revert(on database: Database) async throws {
        // No-op.
    }
}
