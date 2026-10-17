// Tests/APITests/DatasetLibraryFieldDoorTests.swift
//
// The library fields on a dataset spec (`source`, `scope`) are written by the
// library attach path only (docs/datasets-course-library.md, slice 1). The
// doors that edit a sample — the published `PUT /instructor/:id/datasets` and
// MCP `set_dataset` — carry the stored fields through an edit and refuse a
// request that would set or change them.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class DatasetLibraryFieldDoorTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-ds-library-doors")
    }

    private let attachedSpec =
        #"{"file":"cases.csv","kind":"rowSample","sampleSize":2,"#
        + #""source":{"slug":"vitaldb-cases","version":3},"scope":"course","transforms":[]}"#

    private func manifest(datasets: String) -> String {
        """
        {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test_a.sh"}],\
        "timeLimitSeconds":10,"makefile":null,"datasets":[\(datasets)]}
        """
    }

    private struct Fixture {
        let assignment: APIAssignment
        /// An unpublished draft in the same course, with the same zip and specs.
        let draftID: String
        let cookie: String
        let csrf: String
    }

    /// A published assignment and a draft whose zips bundle `cases.csv`, with
    /// `datasets` as their stored specs, and a staff session for their course.
    private func fixture(datasets: String) async throws -> Fixture {
        let course = APICourse(code: "DSLF", name: "Dataset Library Fields", enrollmentMode: .auto)
        try await course.save(on: app.db)
        let courseID = try course.requireID()

        let setupID = "dslf_\(UUID().uuidString.prefix(8))"
        let zipPath = app.testSetupsDirectory + setupID + ".zip"
        try await writeZipFixture(
            at: zipPath, entries: [("cases.csv", "id\n1\n2\n3\n4\n"), ("test_a.sh", "exit 0\n")])
        let setup = APITestSetup(
            id: setupID, manifest: manifest(datasets: datasets), zipPath: zipPath, courseID: courseID)
        try await setup.save(on: app.db)
        let assignment = APIAssignment(
            testSetupID: setupID, title: "Cohort Lab",
            dueAt: nil, isOpen: true, deadlineOverrideActive: false, courseID: courseID)
        try await assignment.save(on: app.db)

        let draftID = "dslfdraft_\(UUID().uuidString.prefix(8))"
        let draftZip = app.testSetupsDirectory + draftID + ".zip"
        try await writeZipFixture(
            at: draftZip, entries: [("cases.csv", "id\n1\n2\n3\n4\n"), ("test_a.sh", "exit 0\n")])
        try await APITestSetup(
            id: draftID, manifest: manifest(datasets: datasets), zipPath: draftZip, courseID: courseID
        ).save(on: app.db)

        let cookie = try await loginUser(username: "dslf_inst", password: "pw", role: "user", on: app)
        // The `.auto` course enrolled the account at sign-in; this makes it staff.
        try await promoteToInstructor("dslf_inst", on: app)
        let (csrf, sessionCookie) = try await csrfFields(
            for: "/instructor/\(assignment.publicID)/edit", cookie: cookie, on: app)
        return Fixture(assignment: assignment, draftID: draftID, cookie: sessionCookie, csrf: csrf)
    }

    private func put(_ fx: Fixture, body: String, path: String? = nil) async throws -> HTTPStatus {
        var status: HTTPStatus = .internalServerError
        try await app.asyncTest(
            .PUT, path ?? "/instructor/\(fx.assignment.publicID)/datasets",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: fx.cookie)
                req.headers.add(name: "x-csrf-token", value: fx.csrf)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: body)
            },
            afterResponse: { res in status = res.status })
        return status
    }

    private func storedSpec(_ fx: Fixture) async throws -> DatasetSpec? {
        try await APITestSetup.find(fx.assignment.testSetupID, on: app.db)?.decodedManifest()?.datasets.first
    }

    // MARK: - The web PUT

    @Test func thePutCarriesTheStoredLibraryFieldsThroughAnEdit() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(datasets: attachedSpec)
            let edited = attachedSpec.replacingOccurrences(of: #""sampleSize":2"#, with: #""sampleSize":3"#)
            #expect(try await put(fx, body: #"{"datasets":["# + edited + "]}") == .ok)
            let spec = try #require(try await storedSpec(fx))
            #expect(spec.sampleSize == 3)
            #expect(spec.source == DatasetSource(slug: "vitaldb-cases", version: 3))
            #expect(spec.scope == .course)
        }
    }

    @Test func thePutRefusesToSetASource() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(datasets: #"{"file":"cases.csv","kind":"rowSample","sampleSize":2}"#)
            let status = try await put(
                fx,
                body: #"{"datasets":[{"file":"cases.csv","sampleSize":2,"#
                    + #""source":{"slug":"vitaldb-cases","version":1}}]}"#)
            #expect(status == .badRequest)
            #expect(try await storedSpec(fx)?.source == nil)
        }
    }

    @Test func thePutRefusesToDropAStoredSource() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(datasets: attachedSpec)
            #expect(try await put(fx, body: #"{"datasets":[{"file":"cases.csv","sampleSize":2}]}"#) == .badRequest)
            #expect(try await storedSpec(fx)?.source != nil)
        }
    }

    @Test func thePutRefusesACourseScopeWithoutASource() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(datasets: "")
            let status = try await put(
                fx, body: #"{"datasets":[{"file":"cases.csv","sampleSize":2,"scope":"course"}]}"#)
            #expect(status == .badRequest)
            #expect(try await storedSpec(fx) == nil)
        }
    }

    // MARK: - The draft PUT

    @Test func theDraftPutRunsTheSameLibraryFieldCheck() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(datasets: attachedSpec)
            let path = "/instructor/new/draft/datasets?draftID=\(fx.draftID)"
            let edited = attachedSpec.replacingOccurrences(of: #""sampleSize":2"#, with: #""sampleSize":3"#)
            #expect(try await put(fx, body: #"{"datasets":["# + edited + "]}", path: path) == .ok)
            #expect(
                try await put(fx, body: #"{"datasets":[{"file":"cases.csv","sampleSize":2}]}"#, path: path)
                    == .badRequest)
            let spec = try #require(
                try await APITestSetup.find(fx.draftID, on: app.db)?.decodedManifest()?.datasets.first)
            #expect(spec.sampleSize == 3)
            #expect(spec.source == DatasetSource(slug: "vitaldb-cases", version: 3))
        }
    }

    // MARK: - MCP set_dataset

    @Test func setDatasetCarriesTheStoredLibraryFieldsThroughAnEdit() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(datasets: attachedSpec)
            let context = ToolContext(
                request: makeTestRequest(on: app), subject: "dslf_inst", grantedScopes: [.read, .write])
            _ = try await SetDatasetTool().execute(
                SetDatasetTool.Input(
                    assignmentPublicID: fx.assignment.publicID, filename: "cases.csv", sampleSize: 3,
                    stratumColumn: nil, remove: nil, transforms: nil),
                context)
            let spec = try #require(try await storedSpec(fx))
            #expect(spec.sampleSize == 3)
            #expect(spec.source == DatasetSource(slug: "vitaldb-cases", version: 3))
            #expect(spec.scope == .course)
        }
    }
}
