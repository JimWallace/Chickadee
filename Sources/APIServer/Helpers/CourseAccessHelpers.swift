// APIServer/Helpers/CourseAccessHelpers.swift
//
// Shared enrollment guard used by any route that accesses per-course content.
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
    let enrolled =
        try await APICourseEnrollment.query(on: db)
        .filter(\.$userID == callerID)
        .filter(\.$course.$id == courseID)
        .count() > 0
    guard enrolled else { throw Abort(.forbidden) }
}
