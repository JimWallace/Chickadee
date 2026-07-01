// APIServer/Migrations/CollapseUserRoles.swift
//
// #417 Slice G2 — collapse the deployment-global user role to `user` | `admin`
// (+ the non-human `mcp` service account). Teaching authority moved per-course
// (`CourseRole` on `course_enrollments`, backfilled by `AddCourseEnrollmentRole`
// *before* this migration runs), so the legacy global `student` / `instructor`
// roles carry no authority any more. Rewrite every such row to `user`.
//
// Ordering matters: this runs AFTER `AddCourseEnrollmentRole` has seeded each
// enrollment's per-course role from the user's *then-current* global role, so no
// authority is lost — a course's instructor is already `.instructor` on their
// enrollment, and only the now-meaningless global label is normalised here.
//
// `admin` and `mcp` rows are left untouched. The revert is intentionally a no-op:
// the pre-collapse `student` / `instructor` distinction can't be reconstructed
// from `user` alone (it now lives per-course), and nothing reads the global role
// for teaching authority any more, so there is nothing to restore.

import Fluent
import SQLKit

struct CollapseUserRoles: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            // Only the SQL drivers (SQLite / Postgres) are used in practice.
            return
        }
        try await sql.update("users")
            .set("role", to: UserRole.user.rawValue)
            .where("role", .equal, UserRole.student.rawValue)
            .run()
        try await sql.update("users")
            .set("role", to: UserRole.user.rawValue)
            .where("role", .equal, UserRole.instructor.rawValue)
            .run()
    }

    func revert(on database: Database) async throws {
        // No-op: the student/instructor split is not recoverable from `user`,
        // and the global role no longer governs teaching authority.
    }
}
