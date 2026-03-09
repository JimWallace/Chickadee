// APIServer/Models/APICourseEnrollment.swift
//
// Join table: a user is enrolled in a course.
// Both students and instructors enroll via the same mechanism.
// The user's global role (student/instructor/admin) determines what they can do;
// enrollment determines which courses they can see.

import Fluent
import Vapor

final class APICourseEnrollment: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: all mutations happen within Vapor's request context.
    static let schema = "course_enrollments"

    @ID(key: .id)
    var id: UUID?

    /// The enrolled user. Stored directly as UUID (not via @Parent) because
    /// APIUser uses UUID as its PK and we don't need eager-loading here.
    @Field(key: "user_id")
    var userID: UUID

    /// The course being enrolled in.
    @Parent(key: "course_id")
    var course: APICourse

    @Timestamp(key: "enrolled_at", on: .create)
    var enrolledAt: Date?

    init() {}

    init(id: UUID? = nil, userID: UUID, courseID: UUID) {
        self.id          = id
        self.userID      = userID
        self.$course.id  = courseID
    }
}
