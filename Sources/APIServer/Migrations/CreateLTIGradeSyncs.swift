// APIServer/Migrations/CreateLTIGradeSyncs.swift
//
// The AGS push queue (docs/lti-1-3.md "Grades through AGS"). New table; it
// must follow CreateUsers. One row per (student, test setup).

import Fluent

struct CreateLTIGradeSyncs: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(APILTIGradeSync.schema)
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("test_setup_id", .string, .required)
            .field("pending", .bool, .required)
            .field("pending_since", .datetime)
            .field("synced_at", .datetime)
            .field("error", .string)
            .unique(on: "user_id", "test_setup_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(APILTIGradeSync.schema).delete()
    }
}
