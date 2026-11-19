import Fluent
import SQLKit

/// Indexes for foreign keys whose referenced rows are deleted in bulk.
///
/// Postgres does not index the referencing side of a foreign key. Without an
/// index, every delete of a referenced row scans the whole referencing table
/// to apply the `ON DELETE` rule. Measured at one course's scale
/// (docs/database-performance.md): `request_metrics` held 422,000 rows, so
/// each deleted submission cost a 34 ms scan. An assignment with about 1,500
/// submissions took about 50 s to delete.
///
/// Submissions, test setups and assignments are deleted many at a time, so
/// their foreign keys get an index here. A user or a course is deleted one at
/// a time, and one scan per delete costs less than an index entry on every
/// insert into a table that takes a row per request or per job.
/// `ForeignKeyIndexCoverageTests` lists those keys with that reason.
///
/// A column that is NULL on most rows gets a partial index. It adds no entry
/// for a row where the column is NULL.
struct CreateForeignKeyIndexes: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else { return }

        try await sql.raw(
            """
            CREATE INDEX IF NOT EXISTS idx_request_metrics_submission ON request_metrics(submission_id) \
            WHERE submission_id IS NOT NULL
            """
        ).run()
        try await sql.raw(
            """
            CREATE INDEX IF NOT EXISTS idx_submissions_retested_by ON submissions(retested_by_user_id) \
            WHERE retested_by_user_id IS NOT NULL
            """
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_job_execution_metrics_setup ON job_execution_metrics(test_setup_id)"
        ).run()
        try await sql.raw(
            """
            CREATE INDEX IF NOT EXISTS idx_job_execution_metrics_assignment ON job_execution_metrics(assignment_id) \
            WHERE assignment_id IS NOT NULL
            """
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_submission_diagnostics_setup ON submission_diagnostics(test_setup_id)"
        ).run()
        try await sql.raw(
            """
            CREATE INDEX IF NOT EXISTS idx_submission_diagnostics_assignment ON submission_diagnostics(assignment_id) \
            WHERE assignment_id IS NOT NULL
            """
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else { return }

        try await sql.raw("DROP INDEX IF EXISTS idx_submission_diagnostics_assignment").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_submission_diagnostics_setup").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_job_execution_metrics_assignment").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_job_execution_metrics_setup").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_submissions_retested_by").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_request_metrics_submission").run()
    }
}
