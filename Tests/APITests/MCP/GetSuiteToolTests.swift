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
            let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
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

    /// Manifest with a section carrying its own variables + expressions.
    private let sectionInputsManifest = #"""
        {"schemaVersion":1,"testSuites":[{"tier":"public","script":"test_a.sh","points":1,"sectionID":"sec1"}],"sections":[{"id":"sec1","name":"Part A","variables":[{"name":"cap","value":7}],"expressions":[{"name":"pick","expression":"seed % 4"}]}],"timeLimitSeconds":10}
        """#

    @Test func returnsSectionVariablesAndExpressions() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
            try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
            try await makeTestSetup(
                on: app, id: "setup_sv", courseID: courseID, manifest: sectionInputsManifest)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_sv", courseID: courseID, title: "Lab")

            let output = try await GetSuiteTool().execute(
                GetSuiteTool.Input(assignmentPublicID: assignment.publicID), context(app))

            let sec = try #require(output.sections.first { $0.id == "sec1" })
            #expect(sec.variables.map(\.name) == ["cap"])
            #expect(sec.variables.first?.value == .int(7))
            #expect(sec.expressions.map(\.name) == ["pick"])
            #expect(sec.expressions.first?.expression == "seed % 4")
        }
    }

    /// Manifest with a pattern family + its generated entry, so we can assert
    /// the family's full spec (function, params, cases with args/expected) is
    /// surfaced — this is what an agent needs to explain a submission's score.
    private let familyManifest = #"""
        {"schemaVersion":1,"testSuites":[{"tier":"public","script":"publictest_tax_01.py","generatedBy":"tax","sectionID":"sec1"}],"patternFamilies":[{"id":"tax","name":"tax — boundary cases","kind":"boundary_equality","functionName":"tax","paramNames":["price"],"defaults":{"tier":"public","points":1},"cases":[{"key":"01","label":"tax(100)","args":[100],"expected":113.0,"enabled":true}]}],"sections":[{"id":"sec1","name":"Functions"}],"timeLimitSeconds":10}
        """#

    @Test func surfacesPatternFamilyCases() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
            try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
            try await makeTestSetup(
                on: app, id: "setup_fam", courseID: courseID, manifest: familyManifest)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_fam", courseID: courseID, title: "Lab")

            let output = try await GetSuiteTool().execute(
                GetSuiteTool.Input(assignmentPublicID: assignment.publicID), context(app))

            let row = try #require(output.items.first { $0.kind == "family" })
            #expect(row.familyID == "tax")
            let family = try #require(row.family)
            #expect(family.functionName == "tax")
            #expect(family.paramNames == ["price"])
            let testCase = try #require(family.cases.first)
            #expect(testCase.key == "01")
            #expect(testCase.label == "tax(100)")
            #expect(testCase.args == [.int(100)])
            // JSONValue normalises the whole-number literal 113.0 to .int(113).
            #expect(testCase.expected == .int(113))
        }
    }

    @Test func deniesWhenSubjectNotEnrolled() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            _ = try await makeTestUser(on: app, username: "tester", role: "instructor")
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
