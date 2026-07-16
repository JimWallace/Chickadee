// APIServer/Migrations/AddCourseBrightSpaceSectionCategoryID.swift
//
// Stores the D2L group category ID whose groups map to the "sections" concept
// for this course (e.g. "Lab Sections" category → Lab 1/2/3 groups).  Nil
// means no section category is configured yet; the section-sync sweep skips
// the course until one is set.

import Fluent

struct AddCourseBrightSpaceSectionCategoryID: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("courses")
            .field("brightspace_section_category_id", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("courses")
            .deleteField("brightspace_section_category_id")
            .update()
    }
}
