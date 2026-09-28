// APIServer/Migrations/AddSubmissionSourceColumns.swift
//
// Where a submission came from (docs/github-submissions.md slice 3). All four
// columns are nil on every existing row, which means an upload.

import Fluent

struct AddSubmissionSourceColumns: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        // One column per update: SQLite alters one column per statement.
        try await database.schema(APISubmission.schema).field("source_kind", .string).update()
        try await database.schema(APISubmission.schema).field("source_repo_id", .int64).update()
        try await database.schema(APISubmission.schema).field("source_repo_name", .string).update()
        try await database.schema(APISubmission.schema).field("source_commit", .string).update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(APISubmission.schema).deleteField("source_commit").update()
        try await database.schema(APISubmission.schema).deleteField("source_repo_name").update()
        try await database.schema(APISubmission.schema).deleteField("source_repo_id").update()
        try await database.schema(APISubmission.schema).deleteField("source_kind").update()
    }
}
