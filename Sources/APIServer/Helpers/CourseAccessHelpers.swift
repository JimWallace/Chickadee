// APIServer/Helpers/CourseAccessHelpers.swift
//
// Shared course-visibility and enrollment-access policy. The web routes and
// the MCP tools both resolve "which courses can this user act on" and "may
// this user touch this course" through the helpers here, so the two surfaces
// cannot drift.
//
// Rule: everyone — instructors included — must be enrolled in the specific
// course that owns the resource. Admins are the one bypass: they administer
// the whole deployment (and can grant themselves enrollment anyway), so
// binding them here adds friction without adding security. Their MCP agents
// are still enrollment-scoped (see ToolContext.authorizeCourseAccess), which
// keeps agent scope ⊆ human scope for every role.

import Core
import Fluent
import Vapor

/// Throws `.forbidden` unless `caller` is an admin or is enrolled in the
/// course identified by `courseID`. Instructors get no bypass: historically
/// any instructor account could fetch another course's content — including
/// test setups carrying secret tests and reference solutions — by URL, even
/// though the dashboard never showed it to them.
func requireCourseEnrollment(caller: APIUser, courseID: UUID, db: Database) async throws {
    guard !caller.isAdmin else { return }
    guard let callerID = caller.id else { throw Abort(.unauthorized) }
    guard try await userIsEnrolled(userID: callerID, inCourse: courseID, db: db) else {
        throw Abort(.forbidden)
    }
}

/// True when the user holds an enrollment row in course `courseID`. The single
/// enrollment predicate behind both the web guard above and the MCP tools'
/// `authorizeCourseAccess`. Deliberately carries no role bypass — role policy
/// stays with the callers.
func userIsEnrolled(userID: UUID, inCourse courseID: UUID, db: Database) async throws -> Bool {
    try await APICourseEnrollment.query(on: db)
        .filter(\.$userID == userID)
        .filter(\.$course.$id == courseID)
        .count() > 0
}

/// The courses the user can act on, dashboard-style: the non-archived courses
/// they hold an enrollment row in, sorted by code. The single visibility
/// resolver behind the web tab strip (`resolveActiveCourse`) and the MCP
/// listing surface (`list_courses`, `resources/list`). No role widens this
/// set: admins see — and their agents may act on — exactly what they are
/// enrolled in. Defined in terms of `enrolledCoursesWithRoles` so the two
/// can't drift on which courses are visible or in what order.
func enrolledCourses(for userID: UUID, on db: Database) async throws -> [APICourse] {
    try await enrolledCoursesWithRoles(for: userID, on: db).map(\.course)
}

/// Like `enrolledCourses`, but pairs each course with the caller's per-course
/// role from the enrollment row (Phase 2 of docs/multi-course-roles.md). The
/// web read path carries this into the nav; the role is web-only and never
/// widens the visible set, and MCP keeps using the role-free `enrolledCourses`.
func enrolledCoursesWithRoles(
    for userID: UUID, on db: Database
) async throws -> [(course: APICourse, role: CourseRole)] {
    let enrollments = try await APICourseEnrollment.query(on: db)
        .filter(\.$userID == userID)
        .with(\.$course)
        .all()
    return
        enrollments
        .filter { !$0.course.isArchived }
        .sorted { $0.course.code < $1.course.code }
        .map { (course: $0.course, role: $0.role) }
}
