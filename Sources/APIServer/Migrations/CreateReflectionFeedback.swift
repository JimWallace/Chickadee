// APIServer/Migrations/CreateReflectionFeedback.swift
//
// One row per (assignment, student) for AI-assisted feedback
// (docs/ai-assisted-feedback.md §"Storage"). The handle is the student's
// pseudonym for that assignment, unique within it. Rows follow their
// assignment and student on delete; the reviewer is only attribution, so it
// nulls out if the staff account is deleted.

import Fluent
import SQLKit

struct CreateReflectionFeedback: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(APIReflectionFeedback.schema)
            .id()
            .field(
                "assignment_id", .uuid, .required,
                .references(APIAssignment.schema, "id", onDelete: .cascade)
            )
            .field(
                "user_id", .uuid, .required,
                .references("users", "id", onDelete: .cascade)
            )
            .field("handle", .string, .required)
            .field("submission_id", .string)
            .field("draft_text", .string)
            .field("state", .string, .required)
            .field("drafted_at", .datetime)
            .field("drafted_by_client", .string)
            .field(
                "reviewed_by_user_id", .uuid,
                .references("users", "id", onDelete: .setNull)
            )
            .field("released_at", .datetime)
            .field("created_at", .datetime)
            .unique(on: "assignment_id", "user_id")
            .unique(on: "assignment_id", "handle")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(APIReflectionFeedback.schema).delete()
    }
}
