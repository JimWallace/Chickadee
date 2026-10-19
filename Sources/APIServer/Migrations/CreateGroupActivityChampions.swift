// APIServer/Migrations/CreateGroupActivityChampions.swift
//
// `group_activity_champions`: one lab group's hill, one row per (assignment,
// group) (docs/lab-groups.md, slice 3b). Rows go with their student. No
// foreign key to the group: a group is removed by `removed_at`, never by a
// delete.

import Fluent

struct CreateGroupActivityChampions: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(APIGroupActivityChampion.schema)
            .id()
            .field("test_setup_id", .string, .required)
            .field("group_id", .uuid, .required)
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("submission_id", .string, .required)
            .field("crowned_at", .datetime, .required)
            .field("defences", .int, .required)
            .unique(on: "test_setup_id", "group_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(APIGroupActivityChampion.schema).delete()
    }
}
