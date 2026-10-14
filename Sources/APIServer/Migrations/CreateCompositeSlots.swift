// APIServer/Migrations/CreateCompositeSlots.swift
//
// The dealt slots of a class composite (docs/class-composite.md, slice 3).

import Fluent

struct CreateCompositeSlots: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(APICompositeSlot.schema)
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
            .field("round", .int, .required)
            .field("dealt_at", .datetime)
            .unique(on: "assignment_id", "user_id")
            .unique(on: "assignment_id", "round", "slot")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(APICompositeSlot.schema).delete()
    }
}
