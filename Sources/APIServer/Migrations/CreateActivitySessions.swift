// APIServer/Migrations/CreateActivitySessions.swift
//
// The sessions of per-group class activities and who joined them by code
// (docs/lab-groups.md, slice 2). A session follows its assignment and its
// group on delete; an attendance row follows its session and its student.

import Fluent

struct CreateActivitySessions: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(APIActivitySession.schema)
            .id()
            .field(
                "assignment_id", .uuid, .required,
                .references(APIAssignment.schema, "id", onDelete: .cascade)
            )
            .field(
                "group_id", .uuid, .required,
                .references(APICourseGroup.schema, "id", onDelete: .cascade)
            )
            .field("code_secret", .string, .required)
            .field("opened_at", .datetime, .required)
            .field("closed_at", .datetime)
            .field("opened_by", .uuid, .references("users", "id", onDelete: .setNull))
            // Folded from AddActivitySessionNetworks: the network part of the
            // presenter's address (`ClientNetwork.prefix`, docs/lab-groups.md,
            // "Presence"). Nil when the request had no readable address.
            .field("presenter_network", .string)
            .unique(on: "assignment_id", "group_id")
            .create()

        try await database.schema(APIActivitySessionAttendance.schema)
            .id()
            .field(
                "session_id", .uuid, .required,
                .references(APIActivitySession.schema, "id", onDelete: .cascade)
            )
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("joined_at", .datetime, .required)
            .field("removed_at", .datetime)
            .field("placed_in_group", .bool, .required)
            // Folded from AddActivitySessionNetworks: the network part of the
            // join's address. Nil when the request had no readable address.
            .field("join_network", .string)
            .unique(on: "session_id", "user_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(APIActivitySessionAttendance.schema).delete()
        try await database.schema(APIActivitySession.schema).delete()
    }
}
