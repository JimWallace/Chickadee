import Fluent
import SQLKit

/// Indexes for hot-path filters the June 2026 audit found uncovered. Each
/// backs a query that runs on a timer or on every dashboard refresh against a
/// table that grows without bound across terms (see `docs/archive/audit-2026-06.md`,
/// finding P1.7).
struct CreateAuditFollowupIndexes: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        // `request_metrics` had no indexes at all, yet every `/api/*` request
        // (including every worker poll) inserts a row, and both the time-series
        // query and the retention prune filter on `finished_at`.
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_request_metrics_finished_at ON request_metrics(finished_at)"
        ).run()

        // Dashboard 24h window + queue-depth queries filter `submitted_at`
        // without a leading status/kind, so the existing
        // (status, kind, submitted_at) composite can't serve them.
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_submissions_submitted_at ON submissions(submitted_at)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_submissions_assigned_at ON submissions(assigned_at)"
        ).run()

        // Admin runner dashboard GROUP BY (polled every 5s) counts submissions
        // per worker by status — a full-table scan without this.
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_submissions_worker_status ON submissions(worker_id, status)"
        ).run()

        // Browser-error student count filters `created_at` only; the existing
        // (test_setup_id, created_at) composite leads with the wrong column.
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_client_diagnostics_created_at ON client_diagnostics(created_at)"
        ).run()

        // Looked up per result report and per claim candidate.
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_assignments_validation_submission_id ON assignments(validation_submission_id)"
        ).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        try await sql.raw("DROP INDEX IF EXISTS idx_assignments_validation_submission_id").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_client_diagnostics_created_at").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_submissions_worker_status").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_submissions_assigned_at").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_submissions_submitted_at").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_request_metrics_finished_at").run()
    }
}
