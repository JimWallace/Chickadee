// APIServer/Models/APICourse.swift
//
// A course groups assignments, submissions, and students together.
// Users enroll in one or more courses. Assignments belong to a course.
//
// Admins manage courses (create, archive). Students and instructors self-enroll.
// When only one course exists, enrollment is automatic and no course UI is shown.

import Fluent
import Vapor

final class APICourse: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: all mutations happen within Vapor's request context.
    static let schema = "courses"

    @ID(key: .id)
    var id: UUID?

    /// Short code shown in the course tab, e.g. "CMSC131".
    @Field(key: "code")
    var code: String

    /// Full display name, e.g. "Introduction to Object-Oriented Programming".
    @Field(key: "name")
    var name: String

    /// Archived courses are hidden from all users and their data is preserved.
    @Field(key: "is_archived")
    var isArchived: Bool

    /// When false, students cannot self-enroll. Admin-managed enrollment still works.
    @Field(key: "open_enrollment")
    var openEnrollment: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Children(for: \.$course)
    var enrollments: [APICourseEnrollment]

    init() {}

    init(id: UUID? = nil, code: String, name: String,
         isArchived: Bool = false, openEnrollment: Bool = true) {
        self.id             = id
        self.code           = code
        self.name           = name
        self.isArchived     = isArchived
        self.openEnrollment = openEnrollment
    }
}
