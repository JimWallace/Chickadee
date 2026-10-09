// APIServer/Migrations/AddAIFeedbackGates.swift
//
// The two opt-in gates for AI-assisted feedback (docs/ai-assisted-feedback.md):
// `courses.ai_feedback_enabled`, set only by a deployment admin, and
// `assignments.ai_feedback_enabled`, set by a course instructor. Both are
// optional; NULL on every existing row reads as off.

import Fluent

struct AddAIFeedbackGates: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(APICourse.schema)
            .field("ai_feedback_enabled", .bool)
            .update()
        try await database.schema(APIAssignment.schema)
            .field("ai_feedback_enabled", .bool)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(APIAssignment.schema)
            .deleteField("ai_feedback_enabled")
            .update()
        try await database.schema(APICourse.schema)
            .deleteField("ai_feedback_enabled")
            .update()
    }
}
