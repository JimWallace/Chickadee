// APIServer/Migrations/CreateCompositeSpares.swift
//
// The spare slots of a class composite, one row per slot
// (docs/class-composite.md, slice 6b).

import Fluent

struct CreateCompositeSpares: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(APICompositeSpare.schema)
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
            .field("data", .string)
            .field("passed", .bool, .required)
            .field("finished", .bool, .required)
            .field("updated_at", .datetime)
            .unique(on: "assignment_id", "slot")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(APICompositeSpare.schema).delete()
    }
}
