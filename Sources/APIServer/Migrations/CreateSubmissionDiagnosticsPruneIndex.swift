import Fluent
import SQLKit

/// Index for the nightly observability prune's sweep of
/// `submission_diagnostics`.
///
/// The prune deletes `finished_at < cutoff`, but the table — 1:1 with
/// `submissions`, so it grows monotonically with every graded job — had no
/// index beyond its primary key, making each nightly pass a full scan that
/// gets slower exactly as the table gets bigger (#1382 item 8). The same
/// index serves the never-finished sweep beside it: a btree on `finished_at`
/// also locates the NULL rows.
struct CreateSubmissionDiagnosticsPruneIndex: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_submission_diagnostics_finished_at ON submission_diagnostics(finished_at)"
        ).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        try await sql.raw("DROP INDEX IF EXISTS idx_submission_diagnostics_finished_at").run()
    }
}
