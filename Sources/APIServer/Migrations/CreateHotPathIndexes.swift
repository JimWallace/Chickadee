import Fluent
import SQLKit

/// Indexes for hot-path filters that `CreatePerformanceIndexes` didn't cover:
/// the BrightSpace sync sweep, the stuck-submission reaper, and the admin
/// runner dashboard / rolling-average queries. Each runs repeatedly (timers or
/// dashboard refreshes) against tables that grow without bound across terms.
struct CreateHotPathIndexes: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        // BrightSpace grade-sync sweep (every 60s): results pending a push,
        // ordered by how long they've been waiting.
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_results_brightspace_pending ON results(brightspace_sync_pending, brightspace_pending_since)"
        ).run()

        // Stuck-submission reaper (periodic): assigned submissions whose
        // assigned_at is older than the cutoff.
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_submissions_status_assigned_at ON submissions(status, assigned_at)"
        ).run()

        // Admin runner dashboard + diagnostics: snapshots for one runner,
        // newest first.
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_runner_snapshots_runner_recorded_at ON runner_snapshots(runner_id, recorded_at)"
        ).run()

        // Admin runner detail + rolling averages: recent jobs for one runner.
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_job_execution_metrics_runner_completed_at ON job_execution_metrics(runner_id, completed_at)"
        ).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        try await sql.raw("DROP INDEX IF EXISTS idx_job_execution_metrics_runner_completed_at").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_runner_snapshots_runner_recorded_at").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_submissions_status_assigned_at").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_results_brightspace_pending").run()
    }
}
