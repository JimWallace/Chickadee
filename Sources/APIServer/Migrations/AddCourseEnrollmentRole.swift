// APIServer/Migrations/AddCourseEnrollmentRole.swift
//
// Phase 1 of per-course roles (docs/multi-course-roles.md): adds the `role`
// column to `course_enrollments` so a user's capability can become
// course-scoped instead of deriving solely from the single global
// `APIUser.role`.
//
// Migration shape mirrors AddUrlTokenToUsers:
//   1. Add `role` as a nullable column (Fluent / SQLite can't add NOT NULL to
//      an existing table cleanly; a nullable column plus the model-side `init`
//      default is the established pattern here).
//   2. Backfill behaviour-preservingly: each existing enrollment's role is
//      seeded from the enrolled user's *current* global role — `.instructor`
//      when the user is a global instructor or admin, else `.student`. So a
//      current global instructor becomes an instructor in every course they
//      are already enrolled in, students stay students, and day-one behaviour
//      is unchanged.
//
// Nothing reads the column yet (later phases wire it into the nav, access
// checks, and the enroll/roster UI), so applying this migration is observably
// a no-op.

import Core
import Fluent
import SQLKit
import Vapor

struct AddCourseEnrollmentRole: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("course_enrollments")
            .field("role", .string)
            .update()

        try await backfillRoles(on: database)
    }

    func revert(on database: Database) async throws {
        try await database.schema("course_enrollments")
            .deleteField("role")
            .update()
    }

    /// One enrollment still needing a role, read with only the columns the
    /// backfill touches — never the full model (see `backfillRoles`).
    private struct PendingEnrollment: Decodable {
        let id: UUID
        let userID: UUID
        enum CodingKeys: String, CodingKey {
            case id
            case userID = "user_id"
        }
    }

    /// Seeds every still-unset enrollment role from the enrolled user's global
    /// role. Split out from `prepare` (which adds the column) so it can be
    /// exercised directly in tests without re-running the column add.
    /// Idempotent — only NULL roles are touched, so re-running is safe.
    ///
    /// Reads and writes `course_enrollments` with raw SQL over only
    /// `id` / `user_id` / `role`, deliberately NOT a full-model
    /// `APICourseEnrollment.query().all()`. A full-model query selects every
    /// column the model *currently* declares, so any column added to
    /// `course_enrollments` by a *later* migration makes this backfill fail on a
    /// fresh database with "no such column" — which is exactly what the
    /// roster-readiness columns did until they were reordered ahead of this
    /// migration (#1077). Scoping the SQL to the three columns it needs removes
    /// that coupling for good.
    func backfillRoles(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else {
            // Only the SQL drivers (SQLite / Postgres) are used. A non-SQL
            // Fluent driver would no-op here, leaving roles to default to
            // `.student` via the model accessor.
            return
        }

        let pending = try await sql.select()
            .column("id")
            .column("user_id")
            .from("course_enrollments")
            .where("role", .is, SQLLiteral.null)
            .all(decoding: PendingEnrollment.self)
        guard !pending.isEmpty else { return }

        // Instructor-ness comes from each user's *global* role at backfill time.
        // This migration runs before `CollapseUserRoles`, so on the DBs where it
        // does real work a user could still carry the legacy `instructor` (or
        // `admin`) role — matched here by its raw string, since those enum cases
        // were retired. The user lookup stays a Fluent model query: it reads the
        // `users` table, which no later migration extends, so it isn't exposed to
        // the column-drift hazard the enrollment query above hardens against.
        let userIDs = Set(pending.map(\.userID))
        let users = try await APIUser.query(on: database).filter(\.$id ~~ userIDs).all()
        let staffRoleStrings: Set<String> = ["instructor", UserRole.admin.rawValue]
        var isInstructorByUserID: [UUID: Bool] = [:]
        for user in users {
            guard let id = user.id else { continue }
            isInstructorByUserID[id] = staffRoleStrings.contains(user.role)
        }

        for row in pending {
            let isInstructor = isInstructorByUserID[row.userID] ?? false
            let roleValue = (isInstructor ? CourseRole.instructor : CourseRole.student).rawValue
            try await sql.update("course_enrollments")
                .set("role", to: roleValue)
                .where("id", .equal, row.id)
                .run()
        }
    }
}
