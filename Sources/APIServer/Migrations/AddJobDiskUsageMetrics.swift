// APIServer/Migrations/AddJobDiskUsageMetrics.swift
//
// CONSOLIDATED.  The disk-usage columns (free_disk_mb_at_start,
// free_disk_mb_at_end, workdir_peak_bytes) are folded into both
// CreateJobExecutionMetrics and CreateSubmissionDiagnostics as of
// v0.4.171.  Struct name preserved so existing prod's
// `_fluent_migrations` tracking is undisturbed; no-op on fresh deploys.

import Fluent

struct AddJobDiskUsageMetrics: AsyncMigration {
    func prepare(on database: Database) async throws {
        // No-op: see CreateJobExecutionMetrics.swift and
        // CreateSubmissionDiagnostics.swift.
    }

    func revert(on database: Database) async throws {
        // No-op.
    }
}
