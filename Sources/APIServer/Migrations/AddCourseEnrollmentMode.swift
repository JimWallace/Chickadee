// APIServer/Migrations/AddCourseEnrollmentMode.swift
//
// CONSOLIDATED.  The `enrollment_mode` column is folded into
// CreateCourses as of v0.4.171.  The historical data migration (mapping
// the legacy `open_enrollment = FALSE` rows to `'closed'`) ran once on
// existing prod and is already reflected in their data.  Fresh deploys
// start with `enrollment_mode` defaulted to `'open'` directly, and never
// have an `open_enrollment` column to migrate from.  Struct name
// preserved so existing prod's `_fluent_migrations` tracking is
// undisturbed.

import Fluent

struct AddCourseEnrollmentMode: AsyncMigration {
    func prepare(on database: Database) async throws {
        // No-op: see CreateCourses.swift.
    }

    func revert(on database: Database) async throws {
        // No-op.
    }
}
