// APIServer/Migrations/AddTestSetupLastRetestedManifestHash.swift

import Fluent

/// Adds `last_retested_manifest_hash` to the test_setups table.
///
/// Records the SHA-256 hex of the `manifest` bytes at the time of the most
/// recent "retest every submission" fan-out.  The auto-retest trigger on
/// assignment save uses this to skip work when the save was a
/// metadata-only edit (name, due date, notebook upload) that doesn't
/// affect grading.  Added in v0.4.93.
struct AddTestSetupLastRetestedManifestHash: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("test_setups")
            .field("last_retested_manifest_hash", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("test_setups")
            .deleteField("last_retested_manifest_hash")
            .update()
    }
}
