// APIServer/Migrations/CreateGroupCompositeSpares.swift
//
// `group_composite_spares`: the spare slots of a class composite that runs
// once per lab group (docs/lab-groups.md, slice 4b), one row per (assignment,
// group, slot). No foreign key to the group: a group is removed by
// `removed_at`, never by a delete.

import Fluent

struct CreateGroupCompositeSpares: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(APIGroupCompositeSpare.schema)
            .id()
            .field(
                "assignment_id", .uuid, .required,
                .references(APIAssignment.schema, "id", onDelete: .cascade)
            )
            .field("group_id", .uuid, .required)
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("slot", .int, .required)
            .field(
                "submission_id", .string, .required,
                .references("submissions", "id", onDelete: .cascade)
            )
            .field("data", .string)
            .field("passed", .bool, .required)
            .field("finished", .bool, .required)
            .field("updated_at", .datetime)
            .unique(on: "assignment_id", "group_id", "slot")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(APIGroupCompositeSpare.schema).delete()
    }
}
