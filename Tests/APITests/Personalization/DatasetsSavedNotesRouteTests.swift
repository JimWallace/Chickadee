// Tests/APITests/Personalization/DatasetsSavedNotesRouteTests.swift
//
// The web `PUT /datasets` names a library sample that the save dropped
// because it covered the whole file (docs/dataset-shared-delivery.md,
// "Whole-file samples"), so the Files panel says so instead of "Saved".

import Core
import Fluent
import Foundation
import NIOFoundationCompat
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) final class DatasetsSavedNotesRouteTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-ds-saved-notes")
    }

    private struct Fixture {
        let assignment: APIAssignment
        let source: DatasetSource
        let cookie: String
        let csrf: String
    }

    /// An assignment with the three-row library file `cases.csv` attached
    /// with a sample of 2, and `notes.csv`, a plain four-row support file.
    private func fixture() async throws -> Fixture {
        let course = APICourse(code: "DSSN", name: "Saved notes", enrollmentMode: .auto)
        try await course.save(on: app.db)
        let courseID = try course.requireID()
        let setupID = "dssn_\(UUID().uuidString.prefix(8))"
        let zipPath = app.testSetupsDirectory + setupID + ".zip"
        try await writeZipFixture(
            at: zipPath, entries: [("test_a.sh", "exit 0\n"), ("notes.csv", "id\n1\n2\n3\n4\n")])
        let setup = APITestSetup(
            id: setupID,
            manifest: #"{"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test_a.sh"}],"#
                + #""timeLimitSeconds":10,"makefile":null}"#,
            zipPath: zipPath, courseID: courseID)
        try await setup.save(on: app.db)
        let assignment = APIAssignment(
            testSetupID: setupID, title: "Saved notes lab", dueAt: nil, isOpen: true, deadlineOverrideActive: false,
            courseID: courseID)
        try await assignment.save(on: app.db)

        let dataset = try await CourseDatasetService.create(
            courseID: courseID,
            dataset: .init(name: "Cases", slug: "cases", description: nil, provenance: nil, licence: nil),
            upload: .init(filename: "cases.csv", bytes: Data("id\n1\n2\n3\n".utf8), note: nil),
            blobs: AssignmentVersionBlobStore(testSetupsDirectory: app.testSetupsDirectory), on: app.db
        ).dataset
        let spec = try await CourseDatasetService.attach(
            dataset, to: setup,
            request: .init(version: nil, filename: nil, sampleSize: 2, stratumColumn: nil, scope: .assignment),
            testSetupsDirectory: app.testSetupsDirectory, on: app.db)

        let cookie = try await loginUser(username: "dssn_inst", password: "pw", role: "user", on: app)
        try await promoteToInstructor("dssn_inst", on: app)
        let (csrf, sessionCookie) = try await csrfFields(
            for: "/instructor/\(assignment.publicID)/edit", cookie: cookie, on: app)
        return Fixture(
            assignment: assignment, source: try #require(spec.source), cookie: sessionCookie, csrf: csrf)
    }

    private func put(_ fx: Fixture, _ datasets: [DatasetSpec]) async throws -> DatasetsResponse {
        var response: DatasetsResponse?
        let body = try JSONEncoder().encode(["datasets": datasets])
        try await app.asyncTest(
            .PUT, "/instructor/\(fx.assignment.publicID)/datasets",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: fx.cookie)
                req.headers.add(name: "x-csrf-token", value: fx.csrf)
                req.headers.contentType = .json
                req.body = ByteBuffer(data: body)
            },
            afterResponse: { res in
                #expect(res.status == .ok)
                response = try res.content.decode(DatasetsResponse.self)
            })
        return try #require(response)
    }

    @Test func aDroppedLibrarySampleIsNamedForItsFile() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let response = try await put(
                fx,
                [
                    DatasetSpec(file: "cases.csv", sampleSize: 3, source: fx.source, scope: .assignment),
                    DatasetSpec(file: "notes.csv", sampleSize: 4),
                ])
            #expect(
                response.savedNotes == [
                    "cases.csv": WholeFileSampleNormalization(file: "cases.csv", sampleSize: 3, dataRowCount: 3)
                        .panelNote
                ])
            #expect(response.datasets.first { $0.file == "cases.csv" }?.sampleSize == nil)
            // A plain file is not normalized, so it has no note.
            #expect(response.datasets.first { $0.file == "notes.csv" }?.sampleSize == 4)
        }
    }

    @Test func aSaveThatKeepsEverySampleHasNoNotes() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let response = try await put(
                fx, [DatasetSpec(file: "cases.csv", sampleSize: 2, source: fx.source, scope: .assignment)])
            #expect(response.savedNotes.isEmpty)
        }
    }
}
