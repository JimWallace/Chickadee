// APIServer/Migrations/CreateUsers.swift

import Fluent

struct CreateUsers: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("users")
            .id()
            .field("username",      .string,   .required)
            .unique(on: "username")
            .field("password_hash", .string,   .required)
            .field("role",          .string,   .required)
            .field("created_at",    .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("users").delete()
    }
}
