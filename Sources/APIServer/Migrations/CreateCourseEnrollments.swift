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
// Existing deploys have this migration already marked applied and never re-run
// it; the folded Add* structs were deleted outright (Fluent ignores
// `_fluent_migrations` rows whose names are no longer registered).

import Fluent

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
            // One enrollment per (user, course) pair.
            .unique(on: "user_id", "course_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("course_enrollments").delete()
    }
}
