// APIServer/Migrations/AddCourseEnrollments.swift

import Fluent

struct AddCourseEnrollments: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("course_enrollments")
            .id()
            .field("user_id",     .uuid,     .required)
            .field(
                "course_id",
                .uuid,
                .required,
                .references("courses", "id", onDelete: .cascade)
            )
            .field("enrolled_at", .datetime)
            // One enrollment per (user, course) pair.
            .unique(on: "user_id", "course_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("course_enrollments").delete()
    }
}
