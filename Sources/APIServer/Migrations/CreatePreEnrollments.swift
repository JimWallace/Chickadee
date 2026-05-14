// APIServer/Migrations/CreatePreEnrollments.swift
//
// v0.4.121: instructors can populate a course roster from a CSV before
// students log in.  Each pre-enrollment is a (course_id, username) pair;
// when a student first authenticates and `APIUser.username` matches a
// row here, the post-login resolver creates a CourseEnrollment and
// deletes the pre-enrollment row.
//
// Kept as a separate table (rather than placeholder APIUser rows) so
// the login flow stays completely untouched — a bug in the resolver
// can leave a student off the roster, but cannot block them from
// signing in.

import Fluent
import SQLKit

struct CreatePreEnrollments: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("pre_enrollments")
            .id()
            .field(
                "course_id",
                .uuid,
                .required,
                .references("courses", "id", onDelete: .cascade)
            )
            .field("username", .string, .required)
            .field("created_at", .datetime, .required)
            // One pending pre-enrollment per (course, username).  Re-uploading
            // a CSV with the same row is idempotent.
            .unique(on: "course_id", "username")
            .create()

        // Index on username so the post-login resolver's lookup is fast
        // (one query per login).  The unique constraint above already
        // covers (course_id, username), but a username-only index is
        // what the resolver actually needs.
        try await (database as? SQLDatabase)?.create(index: "idx_pre_enrollments_username")
            .on("pre_enrollments")
            .column("username")
            .run()
    }

    func revert(on database: Database) async throws {
        try await (database as? SQLDatabase)?.drop(index: "idx_pre_enrollments_username")
            .ifExists()
            .run()
        try await database.schema("pre_enrollments").delete()
    }
}
