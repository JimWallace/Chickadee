// APIServer/Routes/Web/CourseLoaders.swift
//
// Course and section loaders, beside the assignment loaders in
// `AssignmentHelpers.swift` (#2773). Before these existed, each handler
// repeated the same guard: read the path parameter, parse a UUID, find the
// row, throw a 404. The loaders keep the exact status codes and messages of
// the guards they replace.

import Core
import Fluent
import Foundation
import Vapor

// MARK: - Course

/// Loads the course named by the `:courseID` path parameter.
///
/// Returns the course, its UUID and the raw parameter string. Callers use the
/// raw string for redirects and audit `targetID`s, so those stay byte-identical
/// to what the client sent.
///
/// Throws `AppError.notFound(resource: "Course")` (404, "Course not found")
/// when the parameter is missing, is not a UUID, or names no course.
///
/// Performs **no authorization**. The `/admin` group gates the admin callers.
/// A per-course handler goes through `loadCourseForWrite(_:atLeast:)`, or
/// applies its own gate at once after loading.
func loadCourse(_ req: Request) async throws -> (course: APICourse, id: UUID, idString: String) {
    guard
        let idString = req.parameters.get("courseID"),
        let courseID = UUID(uuidString: idString),
        let course = try await APICourse.find(courseID, on: req.db)
    else {
        throw AppError.notFound(resource: "Course")
    }
    return (course, courseID, idString)
}

/// Write-authorizing sibling of `loadCourse(_:)`. After loading, authorizes
/// the caller for a write to that course with `requireCourseWriteAccess`
/// (per-course role, admin bypass, archived-course block).
func loadCourseForWrite(
    _ req: Request, atLeast: CourseRole
) async throws -> (course: APICourse, id: UUID, idString: String) {
    let loaded = try await loadCourse(req)
    let caller = try req.auth.require(APIUser.self)
    try await requireCourseWriteAccess(caller: caller, courseID: loaded.id, atLeast: atLeast, db: req.db)
    return loaded
}

// MARK: - Course section

/// Loads the course section named by the `:sectionID` path parameter, and
/// authorizes `caller` for a write to the section's course.
///
/// The section must belong to `courseID` (the caller's active course). A
/// section of another course reads as missing, not as forbidden, so a URL
/// does not tell a caller that a section exists elsewhere.
///
/// Throws `AppError.notFound(resource: "Section")` (404, "Section not found")
/// when the parameter is missing, is not a UUID, names no section, or names a
/// section of another course. The write check throws as
/// `requireCourseWriteAccess` does.
func loadCourseSectionForWrite(
    _ req: Request, caller: APIUser, inCourse courseID: UUID, atLeast: CourseRole
) async throws -> APICourseSection {
    guard
        let sectionIDString = req.parameters.get("sectionID"),
        let sectionID = UUID(uuidString: sectionIDString),
        let section = try await APICourseSection.find(sectionID, on: req.db),
        section.courseID == courseID
    else {
        throw AppError.notFound(resource: "Section")
    }
    try await requireCourseWriteAccess(
        caller: caller, courseID: section.courseID, atLeast: atLeast, db: req.db)
    return section
}
