// APIServer/Migrations/DropSectionDefaultColumns.swift
//
// The contract step of the section change in docs/assignment-types.md, phase
// 3: drops `course_sections.default_grading_mode` and
// `course_sections.default_assignment_type`. A section names no type and no
// grading mode, and `APICourseSection` maps neither column in v0.5.988 or
// later, so the old color of a blue-green deploy neither reads nor writes
// them during the overlap.
//
// `IF EXISTS`, because `CreateCourses` no longer creates either column: on a
// fresh database there is nothing to drop. The drop takes a brief ACCESS
// EXCLUSIVE lock on `course_sections`, a table of a few rows per course.
//
// A rollback to an older release whose model still maps
// `default_grading_mode` needs the column back: `revert` restores both, with
// the 'worker' default.

import Fluent
import SQLKit

struct DropSectionDefaultColumns: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else { return }
        try await sql.raw(
            """
            ALTER TABLE course_sections \
            DROP COLUMN IF EXISTS default_grading_mode, \
            DROP COLUMN IF EXISTS default_assignment_type
            """
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? (any SQLDatabase) else { return }
        try await sql.raw(
            """
            ALTER TABLE course_sections \
            ADD COLUMN IF NOT EXISTS default_grading_mode TEXT NOT NULL DEFAULT 'worker', \
            ADD COLUMN IF NOT EXISTS default_assignment_type TEXT
            """
        ).run()
    }
}
