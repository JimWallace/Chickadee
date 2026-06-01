// APIServer/Models/APIPreEnrollment.swift
//
// Pending course enrollment, keyed by username, for students who haven't
// logged in yet.  Created in bulk by the CSV-enroll handler; resolved by
// the post-login hook after `APIUser.username` is known to match.
//
// Lifecycle:
//   - Created when bulk-enroll receives a username that has no APIUser row.
//   - Deleted when the matching student first signs in (post-login hook
//     creates an APICourseEnrollment, then deletes this row).
//   - Cleaned up automatically if the course is deleted (CASCADE).
//
// Kept separate from APIUser so the login flow doesn't depend on the
// pre-enrollment lookup — a bug in the resolver can leave a student
// off the roster, but cannot block them from signing in.

import Fluent
import Vapor

final class APIPreEnrollment: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "pre_enrollments"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "course_id")
    var course: APICourse

    /// `APIUser.username` we expect a future student to match.  Compared
    /// case-sensitively at resolution time.
    @Field(key: "username")
    var username: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, courseID: UUID, username: String) {
        self.id = id
        self.$course.id = courseID
        self.username = username
    }
}
