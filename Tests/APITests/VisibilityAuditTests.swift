// Tests/APITests/VisibilityAuditTests.swift
//
// Each open or close of an assignment by a person writes one audit row, with
// the door it came through (#2489). The web `/open` route, the Save close and
// the MCP content-edit close used to write none.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class VisibilityAuditTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-visibility-audit")
    }

    private static let manifest = """
        {"schemaVersion":1,"gradingMode":"worker","language":"python","languageDeclared":true,\
        "requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}
        """
    private static let solutionJSON = """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","source":["x = 1"],"metadata":{},"outputs":[],"execution_count":null}]}
        """

    private struct Fixture {
        let assignment: APIAssignment
        let csrf: String
        let sessionCookie: String
    }

    /// An assignment with a draft solution, and an instructor of its course.
    private func fixture(isOpen: Bool) async throws -> Fixture {
        let course = try await makeTestCourse(on: app, code: "VISAUD", mode: .closed)
        let courseID = try course.requireID()
        try await makeTestSetup(on: app, id: "visaud_setup", courseID: courseID, manifest: Self.manifest)
        let draftPath =
            try ensureDraftNotebookDirectory(
                testSetupsDirectory: app.testSetupsDirectory, setupID: "visaud_setup")
            + "solution.ipynb"
        try Data(Self.solutionJSON.utf8).write(to: URL(fileURLWithPath: draftPath))
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: "visaud_setup", courseID: courseID, title: "Lab 1", isOpen: isOpen)

        let cookie = try await loginUser(username: "visaud_inst", password: "pw", role: "student", on: app)
        let user = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "visaud_inst").first())
        try await APICourseEnrollment(userID: try user.requireID(), courseID: courseID, role: .instructor)
            .save(on: app.db)
        let (csrf, sessionCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)
        return Fixture(assignment: assignment, csrf: csrf, sessionCookie: sessionCookie)
    }

    private func visibilityRows() async throws -> [[String: String]] {
        try await APIAuditLogEntry.query(on: app.db)
            .filter(\.$action == AuditAction.assignmentVisibilityChanged.rawValue)
            .all()
            .map(\.metadataDictionary)
    }

    private func post(_ path: String, _ fixture: Fixture, fields: [String: String] = [:]) async throws {
        var body = fields
        body["_csrf"] = fixture.csrf
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: fixture.sessionCookie)
                try req.content.encode(body, as: .urlEncodedForm)
            },
            afterResponse: { res in
                #expect(res.status == .seeOther, "\(path): \(res.body.string)")
            })
    }

    @Test func theWebOpenRouteWritesOneRow() async throws {
        try await withApp(app) { _ in
            let fixture = try await fixture(isOpen: false)
            try await post("/instructor/\(fixture.assignment.publicID)/open", fixture)

            let rows = try await visibilityRows()
            #expect(rows.count == 1)
            #expect(rows.first?["visibility"] == "open")
            #expect(rows.first?["via"] == "web")
        }
    }

    @Test func theSaveCloseWritesOneRow() async throws {
        try await withApp(app) { _ in
            let fixture = try await fixture(isOpen: true)
            try await post(
                "/instructor/\(fixture.assignment.publicID)/edit/save", fixture,
                fields: ["assignmentName": "Lab 1", "dueAt": "", "startsAt": ""])

            let rows = try await visibilityRows()
            #expect(rows.count == 1)
            #expect(rows.first?["visibility"] == "closed")
            #expect(rows.first?["reason"] == "save")
        }
    }

    /// A Save on a closed assignment changes no visibility, so it writes no row.
    @Test func aSaveThatClosesNothingWritesNoRow() async throws {
        try await withApp(app) { _ in
            let fixture = try await fixture(isOpen: false)
            try await post(
                "/instructor/\(fixture.assignment.publicID)/edit/save", fixture,
                fields: ["assignmentName": "Lab 1", "dueAt": "", "startsAt": ""])

            #expect(try await visibilityRows().isEmpty)
        }
    }

    @Test func theMCPContentEditCloseWritesOneRow() async throws {
        try await withApp(app) { app in
            let fixture = try await fixture(isOpen: true)
            let context = ToolContext(
                request: Request(application: app, on: app.eventLoopGroup.any()),
                subject: "visaud_inst", grantedScopes: [.write])

            #expect(try await closeOpenAssignmentForContentEdit(fixture.assignment, context: context))

            let rows = try await visibilityRows()
            #expect(rows.count == 1)
            #expect(rows.first?["via"] == "mcp")
            #expect(rows.first?["reason"] == "content-edit")
        }
    }
}
