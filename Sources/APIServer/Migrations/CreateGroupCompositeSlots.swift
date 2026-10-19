// APIServer/Migrations/CreateGroupCompositeSlots.swift
//
// `group_composite_slots`: the dealt slots of a class composite that runs once
// per lab group (docs/lab-groups.md, slice 4). No foreign key to the group: a
// group is removed by `removed_at`, never by a delete.

import Fluent

struct CreateGroupCompositeSlots: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(APIGroupCompositeSlot.schema)
            .id()
            .field(
                "assignment_id", .uuid, .required,
                .references(APIAssignment.schema, "id", onDelete: .cascade)
            )
            .field("group_id", .uuid, .required)
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("slot", .int, .required)
            .field("round", .int, .required)
            .field("dealt_at", .datetime)
            .unique(on: "assignment_id", "user_id")
            .unique(on: "assignment_id", "group_id", "round", "slot")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(APIGroupCompositeSlot.schema).delete()
    }
}
