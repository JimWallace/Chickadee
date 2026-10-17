// Tests/APITests/Personalization/DatasetAttachedSpecRemovalTests.swift
//
// An attached spec is ended by a detach, which keeps the sample
// (docs/datasets-course-library.md, slice 3). The `/datasets` PUT refuses a
// body that leaves a stored attached spec out, and `set_dataset remove:true`
// refuses an attached file, because either would give every student the
// whole file.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) final class DatasetAttachedSpecRemovalTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-ds-attached-removal")
    }

    private struct Fixture {
        let assignment: APIAssignment
        let cookie: String
        let csrf: String
    }

    private func fixture() async throws -> Fixture {
        let course = APICourse(code: "DSRM", name: "Removal", enrollmentMode: .auto)
        try await course.save(on: app.db)
        let courseID = try course.requireID()
        let setupID = "dsrm_\(UUID().uuidString.prefix(8))"
        let zipPath = app.testSetupsDirectory + setupID + ".zip"
        try await writeZipFixture(at: zipPath, entries: [("test_a.sh", "exit 0\n")])
        let setup = APITestSetup(
            id: setupID,
            manifest: #"{"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test_a.sh"}],"#
                + #""timeLimitSeconds":10,"makefile":null}"#,
            zipPath: zipPath, courseID: courseID)
        try await setup.save(on: app.db)
        let assignment = APIAssignment(
            testSetupID: setupID, title: "Removal lab", dueAt: nil, isOpen: true, deadlineOverrideActive: false,
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
            request: .init(version: nil, filename: nil, sampleSize: 2, stratumColumn: nil, scope: .assignment),
            testSetupsDirectory: app.testSetupsDirectory, on: app.db)

        let cookie = try await loginUser(username: "dsrm_inst", password: "pw", role: "user", on: app)
        // The `.auto` course enrolled the account at sign-in; this makes it staff.
        try await promoteToInstructor("dsrm_inst", on: app)
        let (csrf, sessionCookie) = try await csrfFields(
            for: "/instructor/\(assignment.publicID)/edit", cookie: cookie, on: app)
        return Fixture(assignment: assignment, cookie: sessionCookie, csrf: csrf)
    }

    private func storedSpecs(_ fx: Fixture) async throws -> [DatasetSpec] {
        try await APITestSetup.find(fx.assignment.testSetupID, on: app.db)?.decodedManifest()?.datasets ?? []
    }

    @Test func thePutRefusesToDropAnAttachedSpec() async throws {
        try await withApp(app) { app in
            let fx = try await fixture()
            var status: HTTPStatus = .imATeapot
            try await app.asyncTest(
                .PUT, "/instructor/\(fx.assignment.publicID)/datasets",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: fx.cookie)
                    req.headers.add(name: "x-csrf-token", value: fx.csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: #"{"datasets":[]}"#)
                },
                afterResponse: { res in status = res.status })
            #expect(status == .badRequest)
            #expect(try await storedSpecs(fx).first?.source == DatasetSource(slug: "cases", version: 1))
        }
    }

    @Test func setDatasetRefusesToRemoveAnAttachedFile() async throws {
        try await withApp(app) { app in
            let fx = try await fixture()
            await #expect(throws: MCPToolError.self) {
                _ = try await SetDatasetTool().execute(
                    SetDatasetTool.Input(
                        assignmentPublicID: fx.assignment.publicID, filename: "cases.csv", sampleSize: nil,
                        stratumColumn: nil, remove: true, transforms: nil),
                    ToolContext(
                        request: makeTestRequest(on: app), subject: "dsrm_inst", grantedScopes: [.read, .write]))
            }
            #expect(try await storedSpecs(fx).count == 1)
        }
    }
}
