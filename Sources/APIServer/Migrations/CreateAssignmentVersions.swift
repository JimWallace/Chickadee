// APIServer/Migrations/CreateAssignmentVersions.swift
//
// Append-only content-snapshot history for assignments
// (docs/assignment-versioning.md).
//
// Two deliberate schema choices, both explained at length on the model:
//
//   - `test_setup_id` has NO foreign key. `deleteAssignment` hard-deletes the
//     `test_setups` row, so an FK would cascade the history away exactly when
//     recovery matters. `assignment_id` is likewise unconstrained + nullable.
//   - `course_id` cascades. Version rows are instructor content scoped to a
//     course; when the course goes, so does its history (the blobs they
//     reference are reclaimed by a later sweep).
//
// `actor_user_id` sets null rather than cascading: a deleted staff account must
// not take the edit history with it, and `actor_username` is denormalized at
// write time so the attribution survives — same pattern as `audit_log`.

import Fluent
import SQLKit

struct CreateAssignmentVersions: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("assignment_versions")
            .id()
            .field("test_setup_id", .string, .required)
            .field("assignment_id", .uuid)
            .field(
                "course_id",
                .uuid,
                .required,
                .references("courses", "id", onDelete: .cascade)
            )
            .field("version_number", .int, .required)
            .field("manifest", .string, .required)
            .field("manifest_hash", .string, .required)
            .field("file_map", .string, .required)
            .field("notebook_hash", .string)
            .field("snapshot_hash", .string, .required)
            .field(
                "actor_user_id",
                .uuid,
                .references("users", "id", onDelete: .setNull)
            )
            .field("actor_username", .string)
            .field("origin", .string, .required)
            .field("summary", .string)
            .field("restored_from_version", .int)
            .field("created_at", .datetime)
            // Makes concurrent snapshots of the same setup collide on insert
            // instead of silently duplicating a version number; the store
            // retries on the conflict.
            .unique(on: "test_setup_id", "version_number")
            .create()

        // The one hot query: "newest version for this setup" (the dedupe check
        // on every content edit) and "this setup's history, newest first".
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_assignment_versions_setup_number ON assignment_versions(test_setup_id, version_number)"
        ).run()
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_assignment_versions_setup_number").run()
        }
        try await database.schema("assignment_versions").delete()
    }
}
