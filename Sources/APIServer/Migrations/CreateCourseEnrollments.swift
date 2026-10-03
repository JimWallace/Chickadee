// APIServer/Migrations/CreateCourseEnrollments.swift
//
// Canonical `course_enrollments` schema for net-new deploys.  The second
// (0.5.0) consolidation round folded in:
//   - AddEnrollmentBrightSpaceSyncStatus — brightspace_sync_status /
//     brightspace_checked_at / brightspace_sync_detail
//   - AddEnrollmentBrightSpaceSection    — brightspace_section
//   - AddCourseEnrollmentRole            — role (its behaviour-preserving
//     backfill seeded roles from the then-global user role; a fresh table has
//     no rows to seed, so only the column carries forward)
//
// The third round (#1252) folded in:
//   - AddEnrollmentSlipDaysAdjustment    — slip_days_adjustment
//
// The fourth round (#1806) folded in:
//   - AddAvatarIdentity (its enrollment half) — avatar_handle and the
//     partial unique index on (course_id, avatar_handle)
//   - AddAvatarHandleLock                — avatar_handle_locked_at
//
// Existing deploys have this migration already marked applied and never re-run
// it; the folded Add* structs were deleted outright (Fluent ignores
// `_fluent_migrations` rows whose names are no longer registered).

import Fluent
import SQLKit

struct CreateCourseEnrollments: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("course_enrollments")
            .id()
            .field(
                "user_id",
                .uuid,
                .required,
                .references("users", "id", onDelete: .cascade)
            )
            .field(
                "course_id",
                .uuid,
                .required,
                .references("courses", "id", onDelete: .cascade)
            )
            .field("enrolled_at", .datetime)
            // Folded from AddCourseEnrollmentRole (per-course roles, #417).
            // Nullable — the model's typed accessor defaults a NULL to
            // `.student`, and new enrollments write a role at insert time.
            .field("role", .string)
            // Folded from AddEnrollmentBrightSpaceSyncStatus: per-(student,
            // course) LEARN grade-sync readiness, maintained by the
            // roster-readiness sweep. NULL reads as `.unconfirmed`.
            .field("brightspace_sync_status", .string)
            .field("brightspace_checked_at", .datetime)
            .field("brightspace_sync_detail", .string)
            // Folded from AddEnrollmentBrightSpaceSection: the LEARN group name
            // in the course's section category. nil until the sweep resolves it.
            .field("brightspace_section", .string)
            // Folded from AddEnrollmentSlipDaysAdjustment (#1228): staff hand one
            // student extra slip days, or take some back. nil reads as 0.
            .field("slip_days_adjustment", .int)
            // Folded from AddAvatarIdentity: the per-course pseudonym, "Quiet
            // Cedar" (docs/student-avatars.md). nil until first needed.
            .field("avatar_handle", .string)
            // Folded from AddAvatarHandleLock: when the handle stopped being
            // the student's to change. nil = the student may still choose once.
            .field("avatar_handle_locked_at", .datetime)
            // One enrollment per (user, course) pair.
            .unique(on: "user_id", "course_id")
            .create()

        // Folded from AddAvatarIdentity. Handles are unique within a course,
        // the scope where a viewer sees two side by side. The NULL exclusion
        // is what makes lazy materialization safe: without it, two
        // enrollments with no handle yet would collide on NULL under any
        // engine that treats NULLs as equal in a unique index.
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_enrollments_course_handle
                ON course_enrollments (course_id, avatar_handle)
                WHERE avatar_handle IS NOT NULL
                """
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_enrollments_course_handle").run()
        }
        try await database.schema("course_enrollments").delete()
    }
}
