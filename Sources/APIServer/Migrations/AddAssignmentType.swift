// APIServer/Migrations/AddAssignmentType.swift
//
// The declared kind of graded work: Assignment, Lab or Class activity
// (docs/assignment-types.md). Nullable, as for every column added to an
// existing table. `BackfillAssignmentType`, in the data-migration block,
// records a type for every row that exists when this runs.

import Fluent

struct AddAssignmentType: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(APIAssignment.schema)
            .field("assignment_type", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(APIAssignment.schema)
            .deleteField("assignment_type")
            .update()
    }
}
