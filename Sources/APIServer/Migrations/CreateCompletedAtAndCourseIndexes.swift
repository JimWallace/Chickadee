import Fluent
import SQLKit

/// Indexes for three filters that no index served (#2778).
///
/// - `job_execution_metrics(completed_at)`: the error-rate health rule, the
///   diagnostics cards and the nightly prune filter on `completed_at` alone.
///   The only other index, `(runner_id, completed_at)`, leads with the runner,
///   so each of those queries scanned the whole retention window. The sibling
///   tables have the same index already (`idx_request_metrics_finished_at`,
///   `idx_submission_diagnostics_finished_at`).
/// - `course_sections(course_id)` and `course_content_items(course_id)`: every
///   course page loads both by course. Postgres does not index a foreign-key
///   column by itself, and SQLite does not either.
///
/// Index only, with `IF NOT EXISTS`, so a populated table only gets a new
/// index and a rerun does nothing.
struct CreateCompletedAtAndCourseIndexes: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else { return }

        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_job_execution_metrics_completed_at ON job_execution_metrics(completed_at)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_course_sections_course_id ON course_sections(course_id)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_course_content_items_course_id ON course_content_items(course_id)"
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else { return }

        try await sql.raw("DROP INDEX IF EXISTS idx_course_content_items_course_id").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_course_sections_course_id").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_job_execution_metrics_completed_at").run()
    }
}
