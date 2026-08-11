// Tests for CreateAssignmentTool (create a new notebook-based assignment from
// scratch), backed by a real test database.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct CreateAssignmentToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.write]
        )
    }

    private func json(_ raw: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
    }

    private let twoCellNotebook = #"""
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[
        {"cell_type":"markdown","metadata":{},"source":["# Lab"]},
        {"cell_type":"code","metadata":{},"source":["x = 1\n"],"outputs":[],"execution_count":null}
        ]}
        """#

    /// Course CS246 + enrolled instructor "tester".
    private func enrolledCourse(on app: Application) async throws {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
    }

    @Test func createsAssignmentWithNotebook() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            try await enrolledCourse(on: app)
            let output = try await CreateAssignmentTool().execute(
                CreateAssignmentTool.Input(
                    courseCode: "CS246", title: "  New Lab  ", notebook: try json(twoCellNotebook), language: "python"),
                context(app))

            #expect(output.title == "New Lab")
            #expect(output.courseCode == "CS246")
            #expect(output.cellCount == 2)
            #expect(output.isOpen == false)
            #expect(!output.publicID.isEmpty)

            // Assignment + setup persisted; notebook readable; suite empty.
            let assignment = try #require(try await assignmentByPublicID(output.publicID, on: app.db))
            #expect(assignment.validationStatus == nil)
            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            #expect(FileManager.default.fileExists(atPath: setup.zipPath))
            let props = try #require(setup.decodedManifest())
            #expect(props.testSuites.isEmpty)

            let data = try notebookData(for: setup)
            let reloaded = try JSONDecoder().decode(JSONValue.self, from: data)
            guard case .object(let root) = reloaded, case .array(let cells)? = root["cells"] else {
                Issue.record("persisted notebook was not a JSON object with a cells array")
                return
            }
            #expect(cells.count == 2)
        }
    }

    @Test func emptyTitleThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            try await enrolledCourse(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await CreateAssignmentTool().execute(
                    CreateAssignmentTool.Input(
                        courseCode: "CS246", title: "   ", notebook: try json(twoCellNotebook), language: "python"),
                    context(app))
            }
        }
    }

    @Test func unknownCourseThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            try await enrolledCourse(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await CreateAssignmentTool().execute(
                    CreateAssignmentTool.Input(
                        courseCode: "NOPE99", title: "Lab", notebook: try json(twoCellNotebook), language: "python"),
                    context(app))
            }
        }
    }

    @Test func rejectsNotebookWithoutCells() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            try await enrolledCourse(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await CreateAssignmentTool().execute(
                    CreateAssignmentTool.Input(
                        courseCode: "CS246", title: "Lab",
                        notebook: try json(#"{"nbformat":4,"metadata":{}}"#), language: "python"),
                    context(app))
            }
        }
    }

    // MARK: - The language is REQUIRED

    /// An agent must state the language, and this is what makes "must" true.
    ///
    /// Every other test here passes `language: "python"` through the typed
    /// `Input`, so the requirement was enforced only by the schema and by the
    /// non-optional `let language: String` — neither of which any test
    /// exercised. An agent does not build an `Input`; it sends an arguments
    /// object, which the dispatcher decodes. So the omission is asserted at
    /// that seam, on the same `decoded(as:)` call the transport makes.
    @Test func languageIsARequiredArgument() throws {
        guard case .object(let schema) = CreateAssignmentTool.inputSchema,
            case .array(let required) = try #require(schema["required"])
        else {
            Issue.record("create_assignment's input schema is not an object with a required list")
            return
        }
        #expect(required.contains(.string("language")))

        let withoutLanguage = JSONValue.object([
            "courseCode": .string("CS246"),
            "title": .string("Lab"),
            "notebook": try json(twoCellNotebook),
        ])
        #expect(throws: (any Error).self) {
            _ = try withoutLanguage.decoded(as: CreateAssignmentTool.Input.self)
        }

        // And the same arguments WITH it decode, so the assertion above is
        // failing for the missing field rather than for the shape.
        var withLanguage: [String: JSONValue] = [
            "courseCode": .string("CS246"),
            "title": .string("Lab"),
            "notebook": try json(twoCellNotebook),
        ]
        withLanguage["language"] = .string("python")
        let decoded = try JSONValue.object(withLanguage).decoded(as: CreateAssignmentTool.Input.self)
        #expect(decoded.language == "python")
    }

    /// Every language the schema offers is one the tool accepts.
    ///
    /// Derived from `allCases` rather than listed, so a seventh language is
    /// covered the day it exists — and so a schema `enum` that grew a token the
    /// parser rejects (or the reverse) fails here rather than at an agent.
    @Test func everyOfferedLanguageChoiceParses() throws {
        guard case .object(let schema) = CreateAssignmentTool.inputSchema,
            case .object(let properties) = try #require(schema["properties"]),
            case .object(let language) = try #require(properties["language"]),
            case .array(let offered) = try #require(language["enum"])
        else {
            Issue.record("create_assignment's language property does not declare an enum")
            return
        }
        let expected =
            AssignmentLanguage.allCases.map { JSONValue.string($0.rawValue) }
            + [.string(noLanguageChoice)]
        #expect(offered == expected)
        for choice in offered {
            guard case .string(let raw) = choice else { continue }
            #expect(throws: Never.self) { _ = try parseLanguageChoice(raw) }
        }
    }

    @Test func anUnknownLanguageIsRejectedBeforeAnythingIsCreated() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            try await enrolledCourse(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await CreateAssignmentTool().execute(
                    CreateAssignmentTool.Input(
                        courseCode: "CS246", title: "Lab", notebook: try json(twoCellNotebook),
                        language: "cobol"),
                    context(app))
            }
            // Parsed before the course lookup and the setup write, so a bad
            // language leaves nothing half-created behind.
            #expect(try await APITestSetup.query(on: app.db).count() == 0)
        }
    }

    /// `"none"` is an ANSWER, and it round-trips as one.
    ///
    /// nil `language` plus `languageDeclared` is the state the whole rule rests
    /// on: it has to be distinguishable from an assignment nobody has been
    /// asked about, because every downstream refusal reads that difference.
    @Test func declaringNoneRecordsAnAnsweredQuestionWithNoLanguage() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            try await enrolledCourse(on: app)
            let output = try await CreateAssignmentTool().execute(
                CreateAssignmentTool.Input(
                    courseCode: "CS246", title: "Shell Lab", notebook: try json(twoCellNotebook),
                    language: noLanguageChoice),
                context(app))

            let assignment = try #require(try await assignmentByPublicID(output.publicID, on: app.db))
            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            let props = try #require(setup.decodedManifest())
            #expect(props.language == nil)
            #expect(props.languageDeclared == true)
        }
    }

    @Test func deniesWhenSubjectNotEnrolled() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            // Course exists but the instructor isn't enrolled in it.
            _ = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            _ = try await makeTestUser(on: app, username: "tester", role: "instructor")
            await #expect(throws: MCPToolError.self) {
                _ = try await CreateAssignmentTool().execute(
                    CreateAssignmentTool.Input(
                        courseCode: "CS246", title: "Lab", notebook: try json(twoCellNotebook), language: "python"),
                    context(app))
            }
        }
    }
}
