// APIServer/Migrations/AddCourseSections.swift
//
// CONSOLIDATED.  The `course_sections` table is folded into
// CreateCourses; the `section_id` FK on assignments is folded into
// CreateAssignments as of v0.4.171.  Struct name preserved so existing
// prod's `_fluent_migrations` tracking is undisturbed; the body is a
// no-op for fresh deploys since CreateCourses/CreateAssignments produce
// both pieces.

import Fluent

struct AddCourseSections: AsyncMigration {
    func prepare(on database: Database) async throws {
        // No-op: see CreateCourses.swift and CreateAssignments.swift.
    }

    func revert(on database: Database) async throws {
        // No-op.
    }
}
