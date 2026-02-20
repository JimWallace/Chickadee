// APIServer/Migrations/AddAttemptNumberToSubmissions.swift

import Fluent

struct AddAttemptNumberToSubmissions: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("submissions")
            .field("attempt_number", .int)  // nullable — existing rows default to nil, treated as 1
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("submissions")
            .deleteField("attempt_number")
            .update()
    }
}
