// APIServer/Migrations/AddJobExecutionStageTimings.swift
//
// CONSOLIDATED.  The 10 stage-timing columns are folded into
// CreateJobExecutionMetrics as of v0.4.171.  Struct name preserved so
// existing prod's `_fluent_migrations` tracking is undisturbed; no-op
// on fresh deploys.

import Fluent

struct AddJobExecutionStageTimings: AsyncMigration {
    func prepare(on database: Database) async throws {
        // No-op: see CreateJobExecutionMetrics.swift.
    }

    func revert(on database: Database) async throws {
        // No-op.
    }
}
