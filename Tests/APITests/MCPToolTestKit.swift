// Shared setup for the MCP tool tests (#2716): the tool context, and the
// course, the instructor and the assignment that most tool suites seed.

import ChickadeeTestSupport
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

/// Seeds a `TestScenario` (a course, a test setup `setupID` and an assignment
/// on it) and an instructor account called `mcpTestSubject`. With
/// `enroll: false` the account holds no enrollment in the course. A nil
/// `manifest` keeps the `makeTestSetup` default.
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
    let scenario =
        if let manifest {
            try await TestScenario.make(
                on: app, code: courseCode, courseName: courseName, setupID: setupID, manifest: manifest,
                withNotebook: withNotebook, title: title)
        } else {
            try await TestScenario.make(
                on: app, code: courseCode, courseName: courseName, setupID: setupID,
                withNotebook: withNotebook, title: title)
        }
    if enroll {
        try await scenario.enroll(mcpTestSubject, role: "instructor", on: app)
    } else {
        try await makeTestUser(on: app, username: mcpTestSubject, role: "instructor")
    }
    return scenario.assignment
}

/// The account `seedMCPCourse` made for `subject`.
func mcpTestUser(on app: Application, subject: String = mcpTestSubject) async throws -> APIUser {
    guard let user = try await APIUser.query(on: app.db).filter(\.$username == subject).first() else {
        throw IssueRecorded("No seeded MCP test account \"\(subject)\".")
    }
    return user
}
