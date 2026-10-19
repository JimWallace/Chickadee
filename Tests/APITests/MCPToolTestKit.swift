// Shared setup for the MCP tool tests (#2716): the tool context, and the
// course, the instructor and the assignment that most tool suites seed.

import Fluent
import Foundation
import Vapor

@testable import APIServer

/// The account the MCP tool tests act as, unless a test names another.
let mcpTestSubject = "tester"

/// A tool context for `subject` on a fresh request. A tool's `execute` does
/// not read the scopes, but a dispatcher test does, so pass them where the
/// test goes through the dispatcher.
func mcpContext(
    _ app: Application,
    subject: String = mcpTestSubject,
    scopes: Set<ContentScope> = [.read, .write]
) -> ToolContext {
    ToolContext(request: makeTestRequest(on: app), subject: subject, grantedScopes: scopes)
}

/// Seeds a course and an instructor account for it, called `subject`. With
/// `enroll: false` the account exists but holds no enrollment in the course.
@discardableResult
func seedMCPCourse(
    on app: Application,
    code: String = "CS246",
    name: String = "OOP",
    subject: String = mcpTestSubject,
    enroll: Bool = true
) async throws -> APICourse {
    let course = try await makeTestCourse(on: app, code: code, name: name)
    let user = try await makeTestUser(on: app, username: subject, role: "instructor")
    if enroll {
        try await makeTestEnrollment(on: app, userID: user.requireID(), courseID: course.requireID())
    }
    return course
}

/// Seeds `seedMCPCourse`, then a test setup `setupID` and an assignment on
/// it. A nil `manifest` keeps the `makeTestSetup` default.
@discardableResult
func seedMCPAssignment(
    on app: Application,
    setupID: String,
    manifest: String? = nil,
    enroll: Bool = true,
    courseCode: String = "CS246",
    courseName: String = "OOP",
    title: String = "Lab",
    withNotebook: Bool = true
) async throws -> APIAssignment {
    let course = try await seedMCPCourse(on: app, code: courseCode, name: courseName, enroll: enroll)
    let courseID = try course.requireID()
    if let manifest {
        try await makeTestSetup(
            on: app, id: setupID, courseID: courseID, manifest: manifest, withNotebook: withNotebook)
    } else {
        try await makeTestSetup(on: app, id: setupID, courseID: courseID, withNotebook: withNotebook)
    }
    return try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID, title: title)
}
