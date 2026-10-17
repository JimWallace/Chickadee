// APIServer/Migrations/CreateCoursePersonalizationSeeds.swift
//
// The per-student course cohort seed (docs/datasets-course-library.md,
// slice 4). One row per (user, course); the seed is a 64-character hex string.
// Generated the first time a course-scoped dataset is delivered to the
// student. Cascade-deletes follow the user and the course.

import Fluent

struct CreateCoursePersonalizationSeeds: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("course_personalization_seeds")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("course_id", .uuid, .required, .references("courses", "id", onDelete: .cascade))
            .field("seed_value", .string, .required)
            .field("created_at", .datetime)
            .unique(on: "user_id", "course_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("course_personalization_seeds").delete()
    }
}
