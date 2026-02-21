// APIServer/Migrations/AddUserIDToSubmissions.swift
//
// Phase 6: tie submissions to the logged-in user.
// Nullable so existing anonymous submissions remain valid.

import Fluent

struct AddUserIDToSubmissions: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("submissions")
            .field("user_id", .uuid)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("submissions")
            .deleteField("user_id")
            .update()
    }
}
