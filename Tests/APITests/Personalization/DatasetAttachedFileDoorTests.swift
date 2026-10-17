// Tests/APITests/Personalization/DatasetAttachedFileDoorTests.swift
//
// A file attached from the course library is a copy of one library version
// (docs/datasets-course-library.md, slice 3). The doors that write or delete a
// single support file — the web script PUT and DELETE, MCP `author_script` and
// MCP `delete_support_file` — refuse it and point at detach. The `/datasets`
// PUT accepts an attached whole-file spec, which has no sample.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class DatasetAttachedFileDoorTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-ds-attached-doors")
    }

    private struct Fixture {
        let assignment: APIAssignment
        let cookie: String
        let csrf: String
    }

    /// A published assignment with `cases.csv` attached from the library as
    /// the whole file, and a staff session for its course.
    private func fixture() async throws -> Fixture {
        let course = APICourse(code: "DSAF", name: "Attached Files", enrollmentMode: .auto)
        try await course.save(on: app.db)
        let courseID = try course.requireID()
        let setupID = "dsaf_\(UUID().uuidString.prefix(8))"
        let zipPath = app.testSetupsDirectory + setupID + ".zip"
        try await writeZipFixture(at: zipPath, entries: [("test_a.sh", "exit 0\n")])
        let manifest = """
            {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test_a.sh"}],\
            "timeLimitSeconds":10,"makefile":null}
            """
        let setup = APITestSetup(id: setupID, manifest: manifest, zipPath: zipPath, courseID: courseID)
        try await setup.save(on: app.db)
        let assignment = APIAssignment(
            testSetupID: setupID, title: "Cohort Lab", dueAt: nil, isOpen: true, deadlineOverrideActive: false,
            courseID: courseID)
        try await assignment.save(on: app.db)

        let blobs = AssignmentVersionBlobStore(testSetupsDirectory: app.testSetupsDirectory)
        let dataset = try await CourseDatasetService.create(
            courseID: courseID,
            dataset: .init(name: "Cases", slug: "cases", description: nil, provenance: nil, licence: nil),
            upload: .init(filename: "cases.csv", bytes: Data("id\n1\n2\n3\n".utf8), note: nil), blobs: blobs,
            on: app.db
        ).dataset
        try await CourseDatasetService.attach(
            dataset, to: setup,
            request: .init(version: nil, filename: nil, sampleSize: nil, stratumColumn: nil, scope: .assignment),
            testSetupsDirectory: app.testSetupsDirectory, on: app.db)

        let cookie = try await loginUser(username: "dsaf_inst", password: "pw", role: "user", on: app)
        // The `.auto` course enrolled the account at sign-in; this makes it staff.
        try await promoteToInstructor("dsaf_inst", on: app)
        let (csrf, sessionCookie) = try await csrfFields(
            for: "/instructor/\(assignment.publicID)/edit", cookie: cookie, on: app)
        return Fixture(assignment: assignment, cookie: sessionCookie, csrf: csrf)
    }

    private func send(
        _ method: HTTPMethod, _ path: String, _ fx: Fixture, body: String? = nil
    ) async throws -> HTTPStatus {
        var status: HTTPStatus = .internalServerError
        try await app.asyncTest(
            method, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: fx.cookie)
                req.headers.add(name: "x-csrf-token", value: fx.csrf)
                if let body {
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: body)
                }
            },
            afterResponse: { res in status = res.status })
        return status
    }

    private func context() -> ToolContext {
        ToolContext(request: makeTestRequest(on: app), subject: "dsaf_inst", grantedScopes: [.read, .write])
    }

    private func casesText(_ fx: Fixture) async throws -> String? {
        let setup = try #require(try await APITestSetup.find(fx.assignment.testSetupID, on: app.db))
        return await readScriptFromZip(zipPath: setup.zipPath, filename: "cases.csv")
    }

    @Test func theWebDeleteRefusesAnAttachedFile() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let status = try await send(.DELETE, "/instructor/\(fx.assignment.publicID)/scripts/cases.csv", fx)
            #expect(status == .conflict)
            #expect(try await casesText(fx) == "id\n1\n2\n3\n")
        }
    }

    @Test func theWebScriptPutRefusesAnAttachedFile() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let status = try await send(
                .PUT, "/instructor/\(fx.assignment.publicID)/scripts/cases.csv", fx, body: #"{"content":"id\n9\n"}"#)
            #expect(status == .conflict)
            #expect(try await casesText(fx) == "id\n1\n2\n3\n")
        }
    }

    @Test func mcpAuthorScriptRefusesAnAttachedFile() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let json =
                #"{"assignmentPublicID":"\#(fx.assignment.publicID)","filename":"cases.csv","#
                + #""content":"id\n9\n","tier":"support"}"#
            let input = try JSONDecoder().decode(AuthorScriptTool.Input.self, from: Data(json.utf8))
            await #expect(throws: MCPToolError.self) {
                _ = try await AuthorScriptTool().execute(input, self.context())
            }
            #expect(try await casesText(fx) == "id\n1\n2\n3\n")
        }
    }

    @Test func mcpDeleteSupportFileRefusesAnAttachedFile() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let json = #"{"assignmentPublicID":"\#(fx.assignment.publicID)","filename":"cases.csv"}"#
            let input = try JSONDecoder().decode(DeleteSupportFileTool.Input.self, from: Data(json.utf8))
            await #expect(throws: MCPToolError.self) {
                _ = try await DeleteSupportFileTool().execute(input, self.context())
            }
            #expect(try await casesText(fx) == "id\n1\n2\n3\n")
        }
    }

    /// The panel sends every spec on each edit. An attached whole file has no
    /// sample, and the PUT must still accept it.
    @Test func theDatasetsPutAcceptsAnAttachedWholeFile() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let body =
                #"{"datasets":[{"file":"cases.csv","kind":"rowSample","#
                + #""source":{"slug":"cases","version":1},"transforms":[]}]}"#
            #expect(try await send(.PUT, "/instructor/\(fx.assignment.publicID)/datasets", fx, body: body) == .ok)
            let unsourced = #"{"datasets":[{"file":"cases.csv","kind":"rowSample","transforms":[]}]}"#
            #expect(
                try await send(.PUT, "/instructor/\(fx.assignment.publicID)/datasets", fx, body: unsourced)
                    == .badRequest)
        }
    }
}
