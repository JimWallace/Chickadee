// APIServer/Migrations/CreateSubmissions.swift

import Fluent

struct CreateSubmissions: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("submissions")
            .field("id", .string, .identifier(auto: false))
            .field(
                "test_setup_id",
                .string,
                .required,
                .references("test_setups", "id", onDelete: .cascade)
            )
            .field("kind", .string, .required)
            .field("status", .string, .required)
            .field("worker_id", .string)
            .field("zip_path", .string, .required)
            .field("attempt_number", .int, .required)
            .field("filename", .string)
            .field(
                "user_id",
                .uuid,
                .references("users", "id", onDelete: .setNull)
            )
            .field("submitted_at", .datetime)
            .field("assigned_at", .datetime)
            // Folded from AddSubmissionRetestedAt.
            .field("retested_at", .datetime)
            // Folded from AddSubmissionRetestedByUserID.
            .field("retested_by_user_id", .uuid)
            // Folded from AddSubmissionMaterialization: cached once-at-enqueue
            // personalization for validation submissions, so worker poll +
            // download stay eval-free.
            .field("materialization_json", .string)
            // Folded from AddSubmissionSourceColumns (fourth round, #1806):
            // where the submission came from (docs/github-submissions.md
            // slice 3). nil on every column means an upload.
            .field("source_kind", .string)
            .field("source_repo_id", .int64)
            .field("source_repo_name", .string)
            .field("source_commit", .string)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("submissions").delete()
    }
}
