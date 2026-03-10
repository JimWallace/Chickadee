import Fluent
import SQLKit

struct CreatePerformanceIndexes: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        // Worker queue lookup: pending + kind ordered by submission time.
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_submissions_status_kind_submitted_at ON submissions(status, kind, submitted_at)"
        ).run()

        // Student history and attempt-number queries.
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_submissions_setup_user_kind_submitted_at ON submissions(test_setup_id, user_id, kind, submitted_at)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_submissions_setup_kind_submitted_at ON submissions(test_setup_id, kind, submitted_at)"
        ).run()

        // Validation fallback lookup by canonical filename.
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_submissions_setup_kind_filename_submitted_at ON submissions(test_setup_id, kind, filename, submitted_at)"
        ).run()

        // Latest result lookup per submission.
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_results_submission_received_at ON results(submission_id, received_at)"
        ).run()

        // Student roster exports.
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_users_role_username ON users(role, username)"
        ).run()

        // Course FK lookups.
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_assignments_course_id ON assignments(course_id)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_test_setups_course_id ON test_setups(course_id)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_course_enrollments_course_id ON course_enrollments(course_id)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_course_enrollments_user_id ON course_enrollments(user_id)"
        ).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        try await sql.raw("DROP INDEX IF EXISTS idx_course_enrollments_user_id").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_course_enrollments_course_id").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_test_setups_course_id").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_assignments_course_id").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_users_role_username").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_results_submission_received_at").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_submissions_setup_kind_filename_submitted_at").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_submissions_setup_kind_submitted_at").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_submissions_setup_user_kind_submitted_at").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_submissions_status_kind_submitted_at").run()
    }
}
