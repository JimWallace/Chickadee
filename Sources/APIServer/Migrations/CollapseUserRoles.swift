// APIServer/Migrations/CollapseUserRoles.swift
//
// #417 Slice G2 — collapse the deployment-global user role to `user` | `admin`
// (+ the non-human `mcp` service account). Teaching authority moved per-course
// (`CourseRole` on `course_enrollments`), so the legacy global `student` /
// `instructor` roles carry no authority any more. Rewrite every such row to
// `user`.
//
// On the historical DBs where this did real work, the enrollment-role
// backfill (its column since folded into CreateCourseEnrollments by the
// second consolidation round) had already seeded each enrollment's per-course
// role from the user's *then-current* global role before this ran, so no
// authority is lost — a course's instructor is already `.instructor` on their
// enrollment, and only the now-meaningless global label is normalised here.
// On a fresh DB this is a pure no-op (zero rows match).
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
        // The legacy `student` / `instructor` role strings are matched as
        // literals: the enum cases were retired in the G2 cleanup, but old rows
        // in production DBs still carry those exact strings and must be rewritten.
        try await sql.update("users")
            .set("role", to: UserRole.user.rawValue)
            .where("role", .equal, "student")
            .run()
        try await sql.update("users")
            .set("role", to: UserRole.user.rawValue)
            .where("role", .equal, "instructor")
            .run()
    }

    func revert(on database: Database) async throws {
        // No-op: the student/instructor split is not recoverable from `user`,
        // and the global role no longer governs teaching authority.
    }
}
