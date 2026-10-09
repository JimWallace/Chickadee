// APIServer/Migrations/AddAIFeedbackAttestation.swift
//
// `course_enrollments.ai_feedback_attested_at`: when a staff member recorded,
// on the instructor AI agents tab, that they connect only a UW-licensed AI
// account for AI-assisted feedback (docs/ai-assisted-feedback.md). Optional;
// NULL on every existing row reads as "not recorded".

import Fluent

struct AddAIFeedbackAttestation: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(APICourseEnrollment.schema)
            .field("ai_feedback_attested_at", .datetime)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(APICourseEnrollment.schema)
            .deleteField("ai_feedback_attested_at")
            .update()
    }
}
