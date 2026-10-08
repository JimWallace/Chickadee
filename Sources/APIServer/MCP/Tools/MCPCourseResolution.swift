// APIServer/MCP/Tools/MCPCourseResolution.swift
//
// Resolves the `courseCode` argument of the course-scoped MCP tools. Course
// codes are unique per term (docs/course-terms.md), so a bare code can name
// several offerings: the one running now, last term's archived one, and the
// next term's clone. The argument also accepts a course's `urlKey`
// ("CS135-F26"), which names exactly one.

import Core
import Fluent
import Foundation

/// Resolves `key` to one course for `tool`. Access is NOT checked here; the
/// caller authorizes the returned course as before.
///
/// With several matches, an active course beats an archived one, and a
/// course the acting account is enrolled in beats one it is not. If more
/// than one course still remains:
/// - a READ takes the newest term (`courseListPrecedes`), the course a
///   person means by the bare code;
/// - a WRITE is refused with the keys to choose from, because writing into
///   the wrong term is silent and hard to see.
func resolveMCPCourse(
    key rawKey: String, context: ToolContext, forWrite: Bool
) async throws -> APICourse {
    let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let all = try await APICourse.query(on: context.db).all()
    // Match among the active courses first, the way the web resolver does,
    // and fall back to the archived ones only when no active course matches.
    // Matching over everything and then preferring the active subset let an
    // archived legacy course coded "CS243-F26" win the key over an active
    // CS243 in Fall 2026, because the exact-code rule fired before the
    // active filter emptied it (#1778).
    var pool = coursesMatching(key: key, in: all.filter { !$0.isArchived })
    if pool.isEmpty { pool = coursesMatching(key: key, in: all.filter(\.isArchived)) }
    guard !pool.isEmpty else {
        throw MCPToolError.invalidArguments(detail: "No course found with code \"\(key)\".")
    }
    if pool.count > 1 {
        let enrolledIDs = try await context.subjectEnrollments(among: pool.compactMap(\.id))
        let enrolled = pool.filter { $0.id.map(enrolledIDs.contains) ?? false }
        if !enrolled.isEmpty { pool = enrolled }
    }
    let ordered = pool.sorted(by: courseListPrecedes)
    guard let chosen = ordered.first else {
        throw MCPToolError.invalidArguments(detail: "No course found with code \"\(key)\".")
    }
    if forWrite, ordered.count > 1 {
        let choices = ordered.map { course in
            course.term.map { "\(course.urlKey) (\($0.displayName))" } ?? course.urlKey
        }
        throw MCPToolError.invalidArguments(
            detail: "The course code \"\(key)\" names more than one offering: "
                + choices.joined(separator: ", ")
                + ". Pass the course key of the one to change.")
    }
    return chosen
}

/// Resolves a course code or key to its course and authorizes a READ of it
/// (enrollment). Carries no archived block, so archived courses stay readable.
/// Returns the course, not only its id, so a tool can report which offering a
/// bare code resolved to (`courseKey`, `courseTerm`).
func resolveCourse(code: String, context: ToolContext) async throws -> APICourse {
    let course = try await resolveMCPCourse(key: code, context: context, forWrite: false)
    try await context.authorizeCourseAccess(try course.requireID())
    return course
}

/// Write variant of `resolveCourse`: resolves the course by code or key and
/// authorizes a WRITE to it at the caller's role floor (`minimum`), with the
/// archived block. Every course-scoped write tool goes through it.
func resolveCourseForWrite(
    code: String, context: ToolContext, atLeast minimum: CourseRole
) async throws -> APICourse {
    let course = try await resolveMCPCourse(key: code, context: context, forWrite: true)
    try await context.authorizeCourseWriteAccess(try course.requireID(), atLeast: minimum)
    return course
}

/// Resolves an optional course-section id for something in `courseID`
/// (`owner` names it in the error, for example "assignment"): nil for absent,
/// empty or "none", else the id. An id that is malformed or names a section
/// in another course is refused, so a typo surfaces instead of ungrouping.
func resolveCourseSectionID(
    _ raw: String?, inCourse courseID: UUID, owner: String, context: ToolContext
) async throws -> UUID? {
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let trimmed, !trimmed.isEmpty, trimmed.lowercased() != "none" else { return nil }
    guard let uuid = UUID(uuidString: trimmed) else {
        throw MCPToolError.invalidArguments(detail: "courseSectionID \"\(trimmed)\" is not a valid id.")
    }
    guard let section = try await APICourseSection.find(uuid, on: context.db),
        section.courseID == courseID
    else {
        throw MCPToolError.invalidArguments(
            detail: "No course section with id \"\(trimmed)\" in this \(owner)'s course.")
    }
    return uuid
}
