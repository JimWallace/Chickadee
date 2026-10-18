// Tests/APITests/Personalization/DatasetLibraryPanelRoutesTests.swift
//
// The course dataset library in the edit page's Files panel
// (docs/datasets-course-library.md §4.5, slice 5b). Attach copies the newest
// version with course scope, and the edit page then shows where the file
// comes from. Update moves to the newest version. The scope box sets the
// scope. Detach keeps the file, or removes it on request. Promote moves a CSV
// support file into the library, and only a CSV is offered. A dataset of
// another course cannot be attached, and a refusal is a 400 with its reason.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) final class DatasetLibraryPanelRoutesTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-ds-panel")
    }

    private static let libraryCSV = "id,ward,systolic\n1,A,120\n2,B,131\n3,A,118\n"
    private static let newerCSV = "id,ward,systolic\n1,A,121\n2,B,130\n"

    private var blobs: AssignmentVersionBlobStore {
        AssignmentVersionBlobStore(testSetupsDirectory: app.testSetupsDirectory)
    }

    private struct Fixture {
        let courseID: UUID
        let setupID: String
        let assignmentID: String
        let cookie: String
        let csrf: String
        let dataset: APICourseDataset

        var base: String { "/instructor/\(assignmentID)/datasets/library/" }
    }

    /// A course with one published assignment that bundles `cases.csv` and
    /// `notes.txt`, a library dataset `ward-cases` whose file is `lib.csv`,
    /// and an instructor session.
    private func fixture(_ tag: String) async throws -> Fixture {
        let course = APICourse(code: "DLP\(tag)", name: "Library panel", enrollmentMode: .auto)
        try await course.save(on: app.db)
        let courseID = try course.requireID()

        let setupID = "dlp_\(UUID().uuidString.prefix(8))"
        try await writeZipFixture(
            at: app.testSetupsDirectory + setupID + ".zip",
            entries: [("cases.csv", "id,ward\n1,3A\n2,3B\n3,3A\n"), ("notes.txt", "notes")])
        try await makeTestSetup(
            on: app, id: setupID, courseID: courseID,
            manifest: #"{"schemaVersion":1,"requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}"#,
            withNotebook: false, withZip: false)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: courseID, title: "Library lab")

        let dataset = try await CourseDatasetService.create(
            courseID: courseID, dataset: .init(name: "Ward cases", slug: "ward-cases"),
            upload: .init(filename: "lib.csv", bytes: Data(Self.libraryCSV.utf8)), blobs: blobs, on: app.db
        ).dataset

        let username = "dlp_inst_\(tag)"
        let cookie = try await loginUser(username: username, password: "pw", role: "user", on: app)
        try await promoteToInstructor(username, on: app)
        let (csrf, sessionCookie) = try await csrfFields(
            for: "/instructor/\(assignment.publicID)/edit", cookie: cookie, on: app)
        return Fixture(
            courseID: courseID, setupID: setupID, assignmentID: assignment.publicID, cookie: sessionCookie,
            csrf: csrf, dataset: dataset)
    }

    @discardableResult
    private func post(
        _ fx: Fixture, _ op: String, _ body: String, expect expected: HTTPStatus = .ok
    ) async throws -> String {
        var text = ""
        try await app.asyncTest(
            .POST, fx.base + op,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: fx.cookie)
                req.headers.add(name: "x-csrf-token", value: fx.csrf)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: body)
            },
            afterResponse: { res in
                #expect(res.status == expected, "\(op) — got \(res.status): \(res.body.string)")
                text = res.body.string
            })
        return text
    }

    private func editPage(_ fx: Fixture) async throws -> String {
        var html = ""
        try await app.asyncTest(
            .GET, "/instructor/\(fx.assignmentID)/edit",
            beforeRequest: { req in req.headers.add(name: .cookie, value: fx.cookie) },
            afterResponse: { res in
                #expect(res.status == .ok)
                html = res.body.string
            })
        return html
    }

    private func specs(_ fx: Fixture) async throws -> [String: DatasetSpec] {
        let setup = try #require(try await APITestSetup.find(fx.setupID, on: app.db))
        return setup.decodedManifest()?.datasetSpecsByFile ?? [:]
    }

    private func zipEntries(_ fx: Fixture) async -> Set<String> {
        Set(await listZipEntries(zipPath: app.testSetupsDirectory + fx.setupID + ".zip"))
    }

    // MARK: - Attach

    @Test func attachCopiesTheNewestVersionWithCourseScope() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("a")
            let before = try await editPage(fx)
            #expect(before.contains("Ward cases (v1)"), "the attach control lists the library")

            try await post(fx, "attach", #"{"slug":"ward-cases"}"#)
            let spec = try #require(try await specs(fx)["lib.csv"])
            #expect(spec.source == DatasetSource(slug: "ward-cases", version: 1))
            #expect(spec.scope == .course)
            #expect(spec.sampleSize == nil)
            #expect(await zipEntries(fx).contains("lib.csv"))

            let after = try await editPage(fx)
            #expect(after.contains("From Ward cases v1"))
            #expect(after.contains("js-library-scope"))
            #expect(after.contains("js-library-remove"))
        }
    }

    @Test func aDatasetOfAnotherCourseCannotBeAttached() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("b")
            let other = try await makeTestCourse(on: app, code: "DLPX", name: "Other").requireID()
            _ = try await CourseDatasetService.create(
                courseID: other, dataset: .init(name: "Elsewhere", slug: "elsewhere"),
                upload: .init(filename: "far.csv", bytes: Data(Self.libraryCSV.utf8)), blobs: blobs, on: app.db)
            try await post(fx, "attach", #"{"slug":"elsewhere"}"#, expect: .notFound)
            #expect(try await specs(fx).isEmpty)
        }
    }

    @Test func aRefusedAttachIsABadRequestWithItsReason() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("c")
            let text = try await post(
                fx, "attach", #"{"slug":"ward-cases","filename":"cases.csv"}"#, expect: .badRequest)
            #expect(text.contains("cases.csv"))
        }
    }

    // MARK: - Update, scope, detach

    @Test func updateMovesToTheNewestVersion() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("d")
            try await post(fx, "attach", #"{"slug":"ward-cases"}"#)
            _ = try await CourseDatasetService.addVersion(
                to: fx.dataset, upload: .init(filename: "lib.csv", bytes: Data(Self.newerCSV.utf8)), blobs: blobs,
                on: app.db)
            #expect(try await editPage(fx).contains("Update to v2"))

            try await post(fx, "update", #"{"file":"lib.csv"}"#)
            #expect(try await specs(fx)["lib.csv"]?.source?.version == 2)
            let zip = app.testSetupsDirectory + fx.setupID + ".zip"
            #expect(await readScriptFromZip(zipPath: zip, filename: "lib.csv") == Self.newerCSV)
        }
    }

    @Test func theScopeBoxSetsTheScope() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("e")
            try await post(fx, "attach", #"{"slug":"ward-cases"}"#)
            try await post(fx, "scope", #"{"file":"lib.csv","courseScoped":false}"#)
            #expect(try await specs(fx)["lib.csv"]?.scope == .assignment)
            try await post(fx, "scope", #"{"file":"lib.csv","courseScoped":true}"#)
            #expect(try await specs(fx)["lib.csv"]?.scope == .course)
            // A file that is not attached has no scope to set.
            try await post(fx, "scope", #"{"file":"cases.csv","courseScoped":true}"#, expect: .badRequest)
        }
    }

    @Test func detachKeepsTheFileOrRemovesItOnRequest() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("f")
            try await post(fx, "attach", #"{"slug":"ward-cases"}"#)
            try await post(fx, "detach", #"{"file":"lib.csv"}"#)
            #expect(await zipEntries(fx).contains("lib.csv"))
            #expect(try await specs(fx)["lib.csv"]?.source == nil)

            try await post(fx, "attach", #"{"slug":"ward-cases","filename":"lib2.csv"}"#)
            try await post(fx, "detach", #"{"file":"lib2.csv","removeFile":true}"#)
            #expect(!(await zipEntries(fx).contains("lib2.csv")))
            #expect(try await specs(fx)["lib2.csv"] == nil)
        }
    }

    // MARK: - Promote

    @Test func promoteMovesACSVSupportFileIntoTheLibrary() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("g")
            let html = try await editPage(fx)
            // One promote button: for cases.csv, and none for notes.txt.
            #expect(html.components(separatedBy: "js-library-promote").count == 2)

            try await post(fx, "promote", #"{"file":"cases.csv"}"#)
            let promoted = try #require(
                try await CourseDatasetService.find(courseID: fx.courseID, slug: "cases", on: app.db))
            #expect(promoted.name == "cases")
            #expect(!promoted.isPublished)
            #expect(try await specs(fx)["cases.csv"]?.source == DatasetSource(slug: "cases", version: 1))
        }
    }
}
