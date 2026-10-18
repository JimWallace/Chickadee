// APIServer/Migrations/CreateCourseGroups.swift
//
// The group sets, groups and memberships of a course (docs/lab-groups.md,
// slice 1). Three tables in one migration, because none is useful alone.
// Every row follows its course on delete, and a membership also follows its
// user. The unique key (set_id, user_id) is what keeps a person in at most one
// group of a set.

import Fluent

struct CreateCourseGroups: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(APICourseGroupSet.schema)
            .id()
            .field("course_id", .uuid, .required, .references("courses", "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("source", .string, .required)
            .field("external_id", .string)
            .field("created_at", .datetime)
            .field("last_synced_at", .datetime)
            .create()

        try await database.schema(APICourseGroup.schema)
            .id()
            .field(
                "set_id", .uuid, .required,
                .references(APICourseGroupSet.schema, "id", onDelete: .cascade)
            )
            .field("name", .string, .required)
            .field("external_id", .string)
            .field("sort_order", .int, .required)
            .field("removed_at", .datetime)
            .field("created_at", .datetime)
            // NULLs are distinct in a unique key on both SQLite and Postgres,
            // so any number of manual groups (no external id) fit one set.
            .unique(on: "set_id", "external_id")
            .create()

        try await database.schema(APICourseGroupMembership.schema)
            .id()
            .field(
                "set_id", .uuid, .required,
                .references(APICourseGroupSet.schema, "id", onDelete: .cascade)
            )
            .field(
                "group_id", .uuid, .required,
                .references(APICourseGroup.schema, "id", onDelete: .cascade)
            )
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("created_at", .datetime)
            .unique(on: "set_id", "user_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(APICourseGroupMembership.schema).delete()
        try await database.schema(APICourseGroup.schema).delete()
        try await database.schema(APICourseGroupSet.schema).delete()
    }
}
