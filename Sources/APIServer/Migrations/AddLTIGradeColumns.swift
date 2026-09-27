// APIServer/Migrations/AddLTIGradeColumns.swift
//
// The nullable additions slice 4 of docs/lti-1-3.md needs on existing tables.
// All are nil on every existing row, which keeps Valence as the grade
// transport:
//
// - `courses.lti_line_items_url`: the AGS line-items URL from a launch.
// - `courses.lti_grades_enabled`: the instructor chose AGS for the course.
// - `assignments.lti_line_item_url`: the line item an assignment's scores go to.

import Fluent

struct AddLTIGradeColumns: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        // One column per update: SQLite alters one column per statement.
        try await database.schema("courses").field("lti_line_items_url", .string).update()
        try await database.schema("courses").field("lti_grades_enabled", .bool).update()
        try await database.schema(APIAssignment.schema).field("lti_line_item_url", .string).update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(APIAssignment.schema).deleteField("lti_line_item_url").update()
        try await database.schema("courses").deleteField("lti_grades_enabled").update()
        try await database.schema("courses").deleteField("lti_line_items_url").update()
    }
}
