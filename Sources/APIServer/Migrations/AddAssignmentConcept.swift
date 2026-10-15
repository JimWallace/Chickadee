// APIServer/Migrations/AddAssignmentConcept.swift
//
// `assignments.concept`: the lab concept an instructor tags an assignment
// with, for the wardrobe's concept rings (docs/student-wardrobe.md, "Concept
// rings"). Optional; NULL on every existing row reads as no concept.

import Fluent

struct AddAssignmentConcept: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(APIAssignment.schema)
            .field("concept", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(APIAssignment.schema)
            .deleteField("concept")
            .update()
    }
}
