// APIServer/Migrations/CreateDatasetDeals.swift
//
// The deal numbers behind the partition datasets
// (docs/datasets-course-library.md §4.11).

import Fluent

struct CreateDatasetDeals: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(APIDatasetDeal.schema)
            .id()
            .field(
                "assignment_id", .uuid, .required,
                .references(APIAssignment.schema, "id", onDelete: .cascade)
            )
            .field(
                "user_id", .uuid, .required,
                .references("users", "id", onDelete: .cascade)
            )
            .field("deal_number", .int, .required)
            .field("dealt_at", .datetime)
            .unique(on: "assignment_id", "user_id")
            .unique(on: "assignment_id", "deal_number")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(APIDatasetDeal.schema).delete()
    }
}
