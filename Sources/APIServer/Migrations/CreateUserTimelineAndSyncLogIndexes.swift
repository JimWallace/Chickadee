import Fluent
import SQLKit

/// Indexes for three per-view and per-sweep filters that no index served.
///
/// - `submissions(user_id, kind, submitted_at)`: every other submissions index
///   leads with the setup, the status, the worker or a time, so a read of one
///   student's submissions across every setup scanned the whole table, and
///   Postgres 16 has no skip scan. The result page's and the account page's
///   wardrobe grant (`WardrobeUnlockStore.graded` with no setup filter), the
///   submissions list API for a student with no setup filter (`ORDER BY
///   submitted_at`) and the data export all read this way.
/// - `assignment_versions(course_id, created_at)`: the instructor Activity tab
///   (`CourseTimelineService`) reads a course's newest versions. The table's
///   only indexes lead with the setup, so each view scanned and sorted the
///   versions of every course and term.
/// - `brightspace_sync_log(status, attempted_at)`: the BrightSpace health rule
///   reads the errors of a recent window on every sweep. The only index leads
///   with the course.
///
/// Index only, with `IF NOT EXISTS`, so a populated table only gets a new
/// index and a rerun does nothing.
struct CreateUserTimelineAndSyncLogIndexes: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else { return }

        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_submissions_user_kind_submitted_at ON submissions(user_id, kind, submitted_at)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_assignment_versions_course_created ON assignment_versions(course_id, created_at)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_bs_sync_log_status_time ON brightspace_sync_log(status, attempted_at)"
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else { return }

        try await sql.raw("DROP INDEX IF EXISTS idx_bs_sync_log_status_time").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_assignment_versions_course_created").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_submissions_user_kind_submitted_at").run()
    }
}
