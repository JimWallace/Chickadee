// APIServer/Migrations/DropCoveredIndexes.swift
//
// Drops four indexes that another index on the same table already covers.
// `SchemaDesignTests.noIndexIsCoveredByAnother` found them. Each is a leading
// prefix of a wider index, or a duplicate of a unique constraint, so every
// query it served is served by the wider index. Dropping it saves the write
// work that each insert and update spent on it.
//
// - `idx_course_enrollments_user_id`: the unique `(user_id, course_id)`.
// - `idx_assignments_course_id`: `idx_assignments_course_slug`.
// - `idx_user_activity_events_created`: `idx_user_activity_events_created_user`.
// - `idx_assignment_versions_setup_number`: the unique
//   `(test_setup_id, version_number)`.
//
// Each drop is `CONCURRENTLY`. A plain drop takes an ACCESS EXCLUSIVE lock;
// queued behind a long transaction on the table, it would block every read of
// the table while it waits, and the live server reads these tables during a
// blue-green deploy. A concurrent drop cannot run inside a transaction block.
// Fluent runs each migration outside one, which the test suite confirms: it
// runs this migration in every test schema.

import Fluent
import SQLKit

struct DropCoveredIndexes: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else { return }

        try await sql.raw("DROP INDEX CONCURRENTLY IF EXISTS idx_course_enrollments_user_id").run()
        try await sql.raw("DROP INDEX CONCURRENTLY IF EXISTS idx_assignments_course_id").run()
        try await sql.raw("DROP INDEX CONCURRENTLY IF EXISTS idx_user_activity_events_created").run()
        try await sql.raw("DROP INDEX CONCURRENTLY IF EXISTS idx_assignment_versions_setup_number").run()
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
    }
}
