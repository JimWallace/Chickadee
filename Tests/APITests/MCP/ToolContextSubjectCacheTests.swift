// The eligible MCP subject is resolved once per request (#1942).
//
// One write call asked `requireEligibleSubject` up to three times (to
// authorize, then to attribute the retest and the re-validation), and each
// ask was two queries. Write authorization also checked enrollment twice for
// a non-admin. These pin the cache's scope and the admin-only enrollment
// check that replaced the duplicate.

import Core
import Fluent
import Testing
import Vapor

@testable import APIServer

@Suite struct ToolContextSubjectCacheTests {

    private func context(_ app: Application, subject: String = "tester", request: Request? = nil) -> ToolContext {
        ToolContext(
            request: request ?? Request(application: app, on: app.eventLoopGroup.any()),
            subject: subject, grantedScopes: [.read, .write])
    }

    /// An instructor enrolled in one course.
    private func instructor(on app: Application, role: String = "instructor") async throws -> (APIUser, APICourse) {
        let course = try await makeTestCourse(on: app, code: "CACHE", name: "Cache")
        let user = try await makeTestUser(on: app, username: "tester", role: role)
        _ = try await makeTestEnrollment(on: app, userID: user.requireID(), courseID: course.requireID())
        return (user, course)
    }

    /// After the first lookup, the subject loses its staff role. The same
    /// request still gets the user it resolved, so it did not look again; a
    /// new request looks again and is refused.
    @Test func theSubjectIsResolvedOncePerRequest() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let (user, _) = try await instructor(on: app)
            let request = Request(application: app, on: app.eventLoopGroup.any())
            let first = try await context(app, request: request).requireEligibleSubject()
            #expect(first.id == user.id)

            try await APICourseEnrollment.query(on: app.db).delete()

            let again = try await context(app, request: request).requireEligibleSubject()
            #expect(again.id == user.id)
            await #expect(
                throws: MCPToolError.notAuthorized(detail: "Students may not use the MCP interface.")
            ) {
                _ = try await context(app).requireEligibleSubject()
            }
        }
    }

    /// The kept answer belongs to the subject it was resolved for.
    @Test func anotherSubjectOnTheSameRequestIsResolvedAfresh() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await instructor(on: app)
            let request = Request(application: app, on: app.eventLoopGroup.any())
            _ = try await context(app, request: request).requireEligibleSubject()
            await #expect(throws: MCPToolError.notAuthorized(detail: "Unknown token subject.")) {
                _ = try await context(app, subject: "nobody", request: request).requireEligibleSubject()
            }
        }
    }

    /// A refusal is not kept: the next ask looks again.
    @Test func aRefusalIsNotKept() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let request = Request(application: app, on: app.eventLoopGroup.any())
            await #expect(throws: MCPToolError.self) {
                _ = try await context(app, request: request).requireEligibleSubject()
            }
            let (user, _) = try await instructor(on: app)
            let resolved = try await context(app, request: request).requireEligibleSubject()
            #expect(resolved.id == user.id)
        }
    }

    /// `evaluateCourseWrite` exempts an admin, so the separate enrollment
    /// check still refuses an admin's agent in a course the admin is not in.
    @Test func anAdminsAgentStillNeedsAnEnrollmentToWrite() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let other = try await makeTestCourse(on: app, code: "OTHER", name: "Other")
            let (_, enrolled) = try await instructor(on: app, role: "admin")
            try await context(app).authorizeCourseWriteAccess(
                enrolled.requireID(), atLeast: .instructor)
            await #expect(
                throws: MCPToolError.notAuthorized(detail: "The MCP account is not enrolled in the target course.")
            ) {
                try await context(app).authorizeCourseWriteAccess(other.requireID(), atLeast: .ta)
            }
        }
    }

    /// A non-admin with no enrollment gets the same refusal as before, now
    /// from `evaluateCourseWrite`.
    @Test func aNonAdminWithNoEnrollmentIsRefusedTheSameWay() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let other = try await makeTestCourse(on: app, code: "OTHER", name: "Other")
            _ = try await instructor(on: app)
            await #expect(
                throws: MCPToolError.notAuthorized(detail: "The MCP account is not enrolled in the target course.")
            ) {
                try await context(app).authorizeCourseWriteAccess(other.requireID(), atLeast: .ta)
            }
        }
    }
}
