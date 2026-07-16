// APIServer/Migrations/AddEnrollmentBrightSpaceSection.swift
//
// Stores the LEARN group name this student belongs to in the course's
// configured section category (e.g. "Lab 3").  Populated by the periodic
// section-sync sweep; nil until the sweep has run or the student isn't in any
// group.

import Fluent

struct AddEnrollmentBrightSpaceSection: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("course_enrollments")
            .field("brightspace_section", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("course_enrollments")
            .deleteField("brightspace_section")
            .update()
    }
}
