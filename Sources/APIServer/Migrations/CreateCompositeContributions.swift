// APIServer/Migrations/CreateCompositeContributions.swift
//
// The latest contribution of each student to a class composite
// (docs/class-composite.md, slice 4).

import Fluent

struct CreateCompositeContributions: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(APICompositeContribution.schema)
            .id()
            .field(
                "assignment_id", .uuid, .required,
                .references(APIAssignment.schema, "id", onDelete: .cascade)
            )
            .field(
                "user_id", .uuid, .required,
                .references("users", "id", onDelete: .cascade)
            )
            .field("slot", .int, .required)
            .field(
                "submission_id", .string, .required,
                .references("submissions", "id", onDelete: .cascade)
            )
            .field("submitted_at", .datetime, .required)
            .field("width", .int, .required)
            .field("height", .int, .required)
            .field("frames", .int, .required)
            .field("format", .string, .required)
            .field("data", .string, .required)
            .field("passed", .bool, .required)
            .field("updated_at", .datetime)
            .unique(on: "assignment_id", "user_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(APICompositeContribution.schema).delete()
    }
}
