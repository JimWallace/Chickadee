// APIServer/Migrations/CreateTestSetups.swift

import Fluent

struct CreateTestSetups: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("test_setups")
            .field("id",         .string, .identifier(auto: false))
            .field("manifest",   .string, .required)
            .field("zip_path",   .string, .required)
            .field("notebook_path", .string)
            .field(
                "course_id",
                .uuid,
                .required,
                .references("courses", "id", onDelete: .cascade)
            )
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("test_setups").delete()
    }
}
