// APIServer/Migrations/AddAvatarHandleLock.swift
//
// course_enrollments.avatar_handle_locked_at — when a student's class handle
// stopped being theirs to change (docs/student-avatars.md §3).  Set the first
// time the handle is shown to a classmate on a student-visible leaderboard, or
// when the student uses their one change on the account page.  Nullable: nil
// means the student may still choose once, which is the right answer for every
// existing row.
//
// Fold into CreateCourseEnrollments in the next consolidation round once every
// deployment has verifiably applied it.

import Fluent

struct AddAvatarHandleLock: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("course_enrollments")
            .field("avatar_handle_locked_at", .datetime)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("course_enrollments")
            .deleteField("avatar_handle_locked_at")
            .update()
    }
}
