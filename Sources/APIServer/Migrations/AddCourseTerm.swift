// APIServer/Migrations/AddCourseTerm.swift
//
// The year and Waterloo term of each course offering (docs/course-terms.md).
// Both columns are nullable: a course created before terms existed reads as
// "no term recorded" until an admin sets one. Nothing is backfilled, because
// a term guessed from `created_at` would be wrong for every course cloned or
// imported ahead of its term.
//
// Fold into CreateCourses in the next consolidation round once every
// deployment has verifiably applied it.

import Fluent

struct AddCourseTerm: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("courses")
            .field("term_year", .int)
            .update()
        try await database.schema("courses")
            .field("term_season", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("courses")
            .deleteField("term_season")
            .update()
        try await database.schema("courses")
            .deleteField("term_year")
            .update()
    }
}
