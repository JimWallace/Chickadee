// APIServer/Models/APICourse.swift
//
// A course groups assignments, submissions, and students together.
// Users enroll in one or more courses. Assignments belong to a course.
//
// Admins manage courses (create, archive). Enrollment policy is set per course
// via CourseEnrollmentMode: open (self-enroll), auto (all users), or closed (admin-managed).

import Core
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

    /// Enrollment policy stored as raw string in DB; use `enrollmentMode` for typed access.
    @Field(key: "enrollment_mode")
    var enrollmentModeRaw: String

    /// Typed accessor for `enrollmentModeRaw`. Defaults to `.open` if the stored value is unrecognised.
    var enrollmentMode: CourseEnrollmentMode {
        get { CourseEnrollmentMode(rawValue: enrollmentModeRaw) ?? .open }
        set { enrollmentModeRaw = newValue.rawValue }
    }

    /// D2L BrightSpace org unit ID for this course (enables grade sync when set).
    @OptionalField(key: "brightspace_org_unit_id")
    var brightspaceOrgUnitID: String?

    /// When this course was archived. Set by `toggleCourseArchive` when a
    /// course is archived (and cleared when un-archived). Archiving is
    /// Chickadee's "end of term" signal, so this is the anchor for the
    /// submission-retention clock — see `SubmissionRetentionService`. Nil
    /// while the course is active.
    @OptionalField(key: "archived_at")
    var archivedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Children(for: \.$course)
    var enrollments: [APICourseEnrollment]

    init() {}

    init(
        id: UUID? = nil, code: String, name: String,
        isArchived: Bool = false, enrollmentMode: CourseEnrollmentMode = .open,
        brightspaceOrgUnitID: String? = nil
    ) {
        self.id = id
        self.code = code
        self.name = name
        self.isArchived = isArchived
        self.enrollmentModeRaw = enrollmentMode.rawValue
        self.brightspaceOrgUnitID = brightspaceOrgUnitID
    }
}
