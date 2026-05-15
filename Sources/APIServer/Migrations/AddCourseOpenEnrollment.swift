// APIServer/Migrations/AddCourseOpenEnrollment.swift
//
// CONSOLIDATED.  The original `open_enrollment` column was already
// dropped by AddCourseEnrollmentMode (which replaced it with the
// three-state `enrollment_mode` string).  As of v0.4.171,
// `enrollment_mode` is in CreateCourses directly, so this migration's
// historical work is captured upstream.  Struct name preserved so
// existing prod's `_fluent_migrations` tracking is undisturbed.

import Fluent

struct AddCourseOpenEnrollment: AsyncMigration {
    func prepare(on database: Database) async throws {
        // No-op: see CreateCourses.swift.
    }

    func revert(on database: Database) async throws {
        // No-op.
    }
}
