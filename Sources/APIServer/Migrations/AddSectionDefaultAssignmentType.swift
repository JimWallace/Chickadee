// APIServer/Migrations/AddSectionDefaultAssignmentType.swift
//
// A course section names an optional default assignment type in place of a
// default grading mode (docs/assignment-types.md, phase 3). Grading follows
// the declared type, so the section no longer carries a mode.
//
// Expand step of an expand-contract change (docs/zero-downtime-deploy.md):
//
// - Adds the nullable `default_assignment_type` column.
// - Gives the old `default_grading_mode` column a database default of
//   "worker". The model no longer maps it, so a section created by this
//   release omits it, and the old color of a blue-green deploy still reads a
//   value from every row during the overlap. A later release drops it.
// - Records "lab" on every section whose default grading mode was "browser":
//   a new assignment there was a browser-graded Lab before this release, and
//   it stays one by default. A "worker" section gets no default, which leaves
//   the new-assignment page on Assignment, the same worker grading as before.
//
// It reads and writes `course_sections` only. No assignment's grading mode or
// type changes.

import Fluent
import SQLKit

struct AddSectionDefaultAssignmentType: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("course_sections")
            .field("default_assignment_type", .string)
            .update()
        guard let sql = database as? (any SQLDatabase) else { return }
        try await sql.raw(
            "ALTER TABLE course_sections ALTER COLUMN default_grading_mode SET DEFAULT 'worker'"
        ).run()
        try await sql.raw(
            """
            UPDATE course_sections SET default_assignment_type = 'lab' \
            WHERE default_grading_mode = 'browser' AND default_assignment_type IS NULL
            """
        ).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? (any SQLDatabase) {
            try await sql.raw(
                "ALTER TABLE course_sections ALTER COLUMN default_grading_mode DROP DEFAULT"
            ).run()
        }
        try await database.schema("course_sections")
            .deleteField("default_assignment_type")
            .update()
    }
}
