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

import Fluent
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

    /// Seeds every still-unset enrollment role from the enrolled user's global
    /// role. Split out from `prepare` (which adds the column) so it can be
    /// exercised directly in tests without re-running the column add.
    /// Idempotent — only NULL roles are touched, so re-running is safe.
    func backfillRoles(on database: Database) async throws {
        let enrollments = try await APICourseEnrollment.query(on: database).all()

        // Distinct users that still need a role, fetched in one IN-query
        // rather than a lookup per enrollment row.
        let pendingUserIDs = Set(enrollments.compactMap { $0.roleRaw == nil ? $0.userID : nil })
        guard !pendingUserIDs.isEmpty else { return }

        let users = try await APIUser.query(on: database)
            .filter(\.$id ~~ pendingUserIDs)
            .all()
        var isInstructorByUserID: [UUID: Bool] = [:]
        for user in users {
            guard let id = user.id else { continue }
            isInstructorByUserID[id] = user.isInstructor
        }

        for enrollment in enrollments where enrollment.roleRaw == nil {
            let isInstructor = isInstructorByUserID[enrollment.userID] ?? false
            enrollment.role = isInstructor ? .instructor : .student
            try await enrollment.save(on: database)
        }
    }
}
