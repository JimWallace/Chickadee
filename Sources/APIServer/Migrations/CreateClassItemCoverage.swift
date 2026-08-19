// APIServer/Migrations/CreateClassItemCoverage.swift

import Fluent

struct CreateClassItemCoverage: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("class_item_coverage")
            .id()
            .field("test_setup_id", .string, .required)
            .field("item", .string, .required)
            .field("user_id", .uuid, .required)
            .field("submission_id", .string, .required)
            .field("covered_at", .datetime)
            // First finder wins. The constraint is not decoration: it is what
            // makes the union monotone and idempotent under retests, replayed
            // reports and concurrent submissions.
            .unique(on: "test_setup_id", "item")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("class_item_coverage").delete()
    }
}
