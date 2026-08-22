// APIServer/Migrations/AddAvatarIdentity.swift
//
// The two columns behind generated student avatars (docs/student-avatars.md):
//
//   users.avatar_spec              — the five slot choices, as JSON.  Nullable
//                                    on purpose: it is materialized the first
//                                    time an avatar is needed, so there is no
//                                    backfill and nobody who never looks at
//                                    their account page ever gets a row write.
//   course_enrollments.avatar_handle — the per-course pseudonym, "Quiet Cedar".
//
// Handles are unique WITHIN a course and not across the deployment, because
// that is the scope where a viewer sees two of them side by side.  The partial
// index is what makes lazy materialization safe: without the NULL exclusion,
// the second enrollment to be created — both with no handle yet — collides on
// NULL under any engine that treats NULLs as equal in a unique index.

import Fluent
import SQLKit

struct AddAvatarIdentity: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("users")
            .field("avatar_spec", .string)
            .update()
        try await database.schema("course_enrollments")
            .field("avatar_handle", .string)
            .update()

        if let sql = database as? SQLDatabase {
            try await sql.raw(
                """
                CREATE UNIQUE INDEX idx_enrollments_course_handle
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
        try await database.schema("course_enrollments")
            .deleteField("avatar_handle")
            .update()
        try await database.schema("users")
            .deleteField("avatar_spec")
            .update()
    }
}
