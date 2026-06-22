// APIServer/Models/APICourseEnrollment.swift
//
// Join table: a user is enrolled in a course.
// Both students and instructors enroll via the same mechanism.
//
// Each enrollment carries a per-course `role` (CourseRole) — the foundation
// for course-scoped capability, i.e. instructor in one course and student in
// another (see docs/multi-course-roles.md). Phase 1 only *stores* this role:
// the `AddCourseEnrollmentRole` migration adds it and seeds it
// behaviour-preservingly from each user's global role, but nothing reads it
// yet — the global `APIUser.role` still governs what a user can do. Later
// phases move the nav, access checks, and roster UI onto the per-course role.

import Core
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

    /// The user's role *within this course* (`CourseRole`, stored as its raw
    /// string).  Declared optional only because Fluent + SQLite can't add a
    /// NOT NULL column to an existing table post-hoc — the same constraint
    /// that keeps `APIUser.url_token` nullable.  Every row carries a value in
    /// practice: fresh enrollments get one from `init` (defaulting to
    /// `.student`) and the `AddCourseEnrollmentRole` migration backfills
    /// pre-existing rows.  Read it through the typed `role` accessor below,
    /// never this raw column.
    @OptionalField(key: "role")
    var roleRaw: String?

    init() {}

    init(id: UUID? = nil, userID: UUID, courseID: UUID, role: CourseRole = .student) {
        self.id = id
        self.userID = userID
        self.$course.id = courseID
        self.roleRaw = role.rawValue
    }
}

// MARK: - Per-course role

extension APICourseEnrollment {
    /// The enrollment's typed per-course role.  Falls back to `.student` for a
    /// missing or unrecognised stored value — defensive, since every row is
    /// expected to carry a valid role once `AddCourseEnrollmentRole` has run.
    var role: CourseRole {
        get { roleRaw.flatMap(CourseRole.init(rawValue:)) ?? .student }
        set { roleRaw = newValue.rawValue }
    }
}
