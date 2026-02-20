// APIServer/Migrations/AddFilenameToSubmissions.swift

import Fluent

struct AddFilenameToSubmissions: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("submissions")
            .field("filename", .string)   // nullable — existing rows are zips
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("submissions")
            .deleteField("filename")
            .update()
    }
}
