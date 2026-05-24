// Tests for ListCoursesTool, backed by a real test database.

import Fluent
import Testing
import Vapor

@testable import APIServer

@Suite struct ListCoursesToolTests {
    private func context(_ app: Application, subject: String) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: subject,
            grantedScopes: [.read]
        )
    }

    @Test func nonAdminSeesOnlyEnrolledCourses() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let cs136 = try await makeTestCourse(on: app, code: "CS136", name: "Systems")
            _ = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let tester = try await makeTestUser(on: app, username: "tester")
            try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: try cs136.requireID())

            let output = try await ListCoursesTool().execute(
                ListCoursesTool.Input(), context(app, subject: "tester"))
            #expect(output.courses.map(\.code) == ["CS136"])
        }
    }

    @Test func adminSeesAllCourses() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await makeTestCourse(on: app, code: "CS136", name: "Systems")
            _ = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            _ = try await makeTestUser(on: app, username: "boss", role: "admin")

            let output = try await ListCoursesTool().execute(
                ListCoursesTool.Input(), context(app, subject: "boss"))
            #expect(output.courses.map(\.code) == ["CS136", "CS246"])
        }
    }

    @Test func unknownSubjectSeesNoCourses() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await makeTestCourse(on: app, code: "CS136", name: "Systems")
            let output = try await ListCoursesTool().execute(
                ListCoursesTool.Input(), context(app, subject: "ghost"))
            #expect(output.courses.isEmpty)
        }
    }
}
