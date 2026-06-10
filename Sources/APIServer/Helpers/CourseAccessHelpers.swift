// APIServer/Helpers/CourseAccessHelpers.swift
//
// Shared course-visibility and enrollment-access policy. The web routes and
// the MCP tools both resolve "which courses can this user act on" and "may
// this user touch this course" through the helpers here, so the two surfaces
// cannot drift.
//
// Rule: instructors and admins can access all courses; students must be
// enrolled in the specific course that owns the resource.

import Fluent
import Vapor

/// Throws `.forbidden` unless `caller` is an instructor/admin or is enrolled
/// in the course identified by `courseID`.
func requireCourseEnrollment(caller: APIUser, courseID: UUID, db: Database) async throws {
    guard !caller.isInstructor else { return }
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
/// enrolled in.
func enrolledCourses(for userID: UUID, on db: Database) async throws -> [APICourse] {
    let enrollments = try await APICourseEnrollment.query(on: db)
        .filter(\.$userID == userID)
        .with(\.$course)
        .all()
    return
        enrollments
        .map(\.course)
        .filter { !$0.isArchived }
        .sorted { $0.code < $1.code }
}
