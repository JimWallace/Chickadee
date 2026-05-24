// Tests for GetSuiteTool, backed by a real test database.

import Core
import Fluent
import Testing
import Vapor

@testable import APIServer

@Suite struct GetSuiteToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.read]
        )
    }

    private let manifest = """
        {"schemaVersion":1,"testSuites":[\
        {"tier":"public","script":"test_a.sh","points":2,"name":"Test A","sectionID":"sec1"},\
        {"tier":"secret","script":"test_b.sh","points":3,"dependsOn":["test_a.sh"],"sectionID":"sec2"}\
        ],"sections":[{"id":"sec1","name":"Part A"},{"id":"sec2","name":"Part B"}],"timeLimitSeconds":10}
        """

    @Test func returnsSuiteStructureForEnrolledSubject() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            let tester = try await makeTestUser(on: app, username: "tester")
            try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
            try await makeTestSetup(on: app, id: "setup_s", courseID: courseID, manifest: manifest)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_s", courseID: courseID, title: "Lab")

            let output = try await GetSuiteTool().execute(
                GetSuiteTool.Input(assignmentPublicID: assignment.publicID), context(app))

            #expect(output.sections.map(\.name) == ["Part A", "Part B"])
            #expect(output.items.map(\.name) == ["test_a.sh", "test_b.sh"])

            let a = try #require(output.items.first { $0.name == "test_a.sh" })
            #expect(a.kind == "script")
            #expect(a.tier == "public")
            #expect(a.points == 2)
            #expect(a.displayName == "Test A")
            #expect(a.sectionID == "sec1")

            let b = try #require(output.items.first { $0.name == "test_b.sh" })
            #expect(b.tier == "secret")
            #expect(b.points == 3)
            #expect(b.dependsOn == ["test_a.sh"])
            #expect(b.sectionID == "sec2")
        }
    }

    @Test func deniesWhenSubjectNotEnrolled() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            _ = try await makeTestUser(on: app, username: "tester")
            try await makeTestSetup(on: app, id: "setup_s", courseID: courseID, manifest: manifest)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_s", courseID: courseID, title: "Lab")

            await #expect(throws: MCPToolError.self) {
                _ = try await GetSuiteTool().execute(
                    GetSuiteTool.Input(assignmentPublicID: assignment.publicID), context(app))
            }
        }
    }

    @Test func unknownAssignmentThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            await #expect(throws: MCPToolError.self) {
                _ = try await GetSuiteTool().execute(
                    GetSuiteTool.Input(assignmentPublicID: "zzzzzz"), context(app))
            }
        }
    }
}
