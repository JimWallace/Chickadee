// APIServer/Migrations/CreateGroupClassItemCoverage.swift
//
// `group_class_item_coverage`: the items each lab group covered
// (docs/lab-groups.md, slice 5b), one row per (test setup, group, item). No
// foreign key to the group, which is removed by `removed_at`, and none to the
// user: as in `class_item_coverage`, coverage never retreats when a student
// drops.

import Fluent

struct CreateGroupClassItemCoverage: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(APIGroupClassItemCoverage.schema)
            .id()
            .field("test_setup_id", .string, .required)
            .field("group_id", .uuid, .required)
            .field("item", .string, .required)
            .field("user_id", .uuid, .required)
            .field("submission_id", .string, .required)
            .field("covered_at", .datetime)
            .unique(on: "test_setup_id", "group_id", "item")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(APIGroupClassItemCoverage.schema).delete()
    }
}
