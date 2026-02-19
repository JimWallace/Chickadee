// APIServer/Migrations/CreateSubmissions.swift

import Fluent

struct CreateSubmissions: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("submissions")
            .field("id",           .string, .identifier(auto: false))
            .field("test_setup_id",.string, .required)
            .field("status",       .string, .required)
            .field("worker_id",    .string)
            .field("zip_path",     .string, .required)
            .field("submitted_at", .datetime)
            .field("assigned_at",  .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("submissions").delete()
    }
}
