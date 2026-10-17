// APIServer/Models/APICoursePersonalizationSeed.swift
//
// The per-(user, course) seed behind a student's course cohort
// (docs/datasets-course-library.md, D4). A course-scoped dataset spec derives
// the student's rows from this seed and the library slug, so one student gets
// the same rows of one dataset in every assignment of the course.
//
// A server-generated random 32-byte hex string, like the assignment seed. It
// is never shown to the student, and it is denied to the least-privilege MCP
// database role by omission (deploy/sql/mcp-least-privilege-role.sql).

import Fluent
import Vapor

final class APICoursePersonalizationSeed: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: all mutations happen within Vapor's request context.
    static let schema = "course_personalization_seeds"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userID: UUID

    @Field(key: "course_id")
    var courseID: UUID

    @Field(key: "seed_value")
    var seedValue: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, userID: UUID, courseID: UUID, seedValue: String) {
        self.id = id
        self.userID = userID
        self.courseID = courseID
        self.seedValue = seedValue
    }
}
