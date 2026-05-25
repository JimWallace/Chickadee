// APIServer/Migrations/CreateAssignmentParticipations.swift
//
// Durable per-(user, assignment) participation record — one row per student
// who has been given an assignment's materials.  Marks "this student has
// engaged with this assignment" so a closed assignment stays reachable for
// review.  Cascade-deletes follow the parent user / assignment.

import Fluent

struct CreateAssignmentParticipations: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("assignment_participations")
            .id()
            .field(
                "user_id",
                .uuid,
                .required,
                .references("users", "id", onDelete: .cascade)
            )
            .field(
                "assignment_id",
                .uuid,
                .required,
                .references("assignments", "id", onDelete: .cascade)
            )
            .field("first_accessed_at", .datetime)
            .unique(on: "user_id", "assignment_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("assignment_participations").delete()
    }
}
