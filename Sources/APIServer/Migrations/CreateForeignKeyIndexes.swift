// APIServer/Migrations/CreateForeignKeyIndexes.swift
//
// Indexes for foreign keys that had none, and the removal of four indexes that
// another index already covers. `SchemaDesignTests` found both.
//
// Postgres does not index the referencing side of a foreign key. Without an
// index, each parent row a delete removes scans the child table once to
// cascade or to set NULL. The worst case was `request_metrics.submission_id`
// (`ON DELETE SET NULL`): a course purge removes every submission in the
// course, so it scanned the request log once for each of them. The others
// are lookups by parent (a group's members, a section's items) or cascades
// from an assignment or a submission delete.
//
// The four dropped indexes are each a leading prefix of another index on the
// same table, or a duplicate of a unique constraint, so every query they
// served is served by the wider index. Dropping them only saves write work.

import Fluent
import SQLKit

struct CreateForeignKeyIndexes: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else { return }

        // Cascades and SET NULL from a submission, setup or assignment delete.
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_request_metrics_submission_id ON request_metrics(submission_id) WHERE submission_id IS NOT NULL"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_submission_diagnostics_test_setup_id ON submission_diagnostics(test_setup_id)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_job_execution_metrics_test_setup_id ON job_execution_metrics(test_setup_id)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_composite_contributions_submission_id ON composite_contributions(submission_id)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_composite_references_submission_id ON composite_references(submission_id)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_composite_spares_submission_id ON composite_spares(submission_id)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_group_composite_spares_submission_id ON group_composite_spares(submission_id)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_assignment_personalization_seeds_assignment_id ON assignment_personalization_seeds(assignment_id)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_assignment_participations_assignment_id ON assignment_participations(assignment_id)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_secret_reveal_unlocks_assignment_id ON secret_reveal_unlocks(assignment_id)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_slip_day_spends_assignment_id ON slip_day_spends(assignment_id)"
        ).run()

        // Lookups by parent, and cascades from a course, section or group.
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_assignments_section_id ON assignments(section_id)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_course_content_items_section_id ON course_content_items(section_id)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_course_personalization_seeds_course_id ON course_personalization_seeds(course_id)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_course_group_sets_course_id ON course_group_sets(course_id)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_course_group_memberships_group_id ON course_group_memberships(group_id)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_activity_sessions_group_id ON activity_sessions(group_id)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_lti_login_states_platform_id ON lti_login_states(platform_id)"
        ).run()

        // Covered by a wider index or a unique constraint on the same columns.
        try await sql.raw("DROP INDEX IF EXISTS idx_course_enrollments_user_id").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_assignments_course_id").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_user_activity_events_created").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_assignment_versions_setup_number").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else { return }

        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_assignment_versions_setup_number ON assignment_versions(test_setup_id, version_number)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_user_activity_events_created ON user_activity_events(created_at)"
        ).run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_assignments_course_id ON assignments(course_id)").run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_course_enrollments_user_id ON course_enrollments(user_id)"
        ).run()

        for name in [
            "idx_lti_login_states_platform_id", "idx_activity_sessions_group_id",
            "idx_course_group_memberships_group_id", "idx_course_group_sets_course_id",
            "idx_course_personalization_seeds_course_id", "idx_course_content_items_section_id",
            "idx_assignments_section_id", "idx_slip_day_spends_assignment_id",
            "idx_secret_reveal_unlocks_assignment_id", "idx_assignment_participations_assignment_id",
            "idx_assignment_personalization_seeds_assignment_id", "idx_group_composite_spares_submission_id",
            "idx_composite_spares_submission_id", "idx_composite_references_submission_id",
            "idx_composite_contributions_submission_id", "idx_job_execution_metrics_test_setup_id",
            "idx_submission_diagnostics_test_setup_id", "idx_request_metrics_submission_id",
        ] {
            try await sql.raw("DROP INDEX IF EXISTS \(unsafeRaw: name)").run()
        }
    }
}
