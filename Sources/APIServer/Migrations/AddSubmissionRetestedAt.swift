// APIServer/Migrations/AddSubmissionRetestedAt.swift

import Fluent

/// Adds `retested_at` to the submissions table.
/// Set to the timestamp when an instructor triggers a re-test, so wait-time
/// and turnaround statistics can be measured from the re-test request rather
/// than the original submission time.
struct AddSubmissionRetestedAt: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("submissions")
            .field("retested_at", .datetime)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("submissions")
            .deleteField("retested_at")
            .update()
    }
}
