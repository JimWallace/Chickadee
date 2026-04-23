// APIServer/Migrations/AddSubmissionRetestedByUserID.swift

import Fluent

/// Adds `retested_by_user_id` to the submissions table.
///
/// Records which instructor triggered the most recent retest — used by the
/// per-submission / per-assignment retest audit trail added in v0.4.93.
/// Nullable so existing rows (and original student submissions) stay valid;
/// a non-nil value indicates "this submission was retested by user X".
struct AddSubmissionRetestedByUserID: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("submissions")
            .field("retested_by_user_id", .uuid)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("submissions")
            .deleteField("retested_by_user_id")
            .update()
    }
}
