// Tests/APITests/DatasetsRouteRoundTripTests.swift
//
// The Files-panel dataset control reads and writes the datasets endpoints, so
// what it needs proved is the round trip: GET the current specs, PUT the whole
// desired array, and GET back exactly what was stored. Render tests prove the
// templates resolve; they do not exercise page JS, so this covers the contract
// the control depends on rather than the control itself.
//
// Covered on BOTH pairs — `/instructor/:assignmentID/datasets` (edit page) and
// `/instructor/new/draft/datasets` (create page). The draft pair is new, and
// its whole point is that the create page can mark a dataset before publish;
// it shares the apply core (`DatasetEditHelpers.swift`) with the published
// pair, and these tests are what hold the two to the same answers.
//
// Spec-level rejections (traversal, unbundled file) live in
// DatasetsRouteValidationTests; what is asserted here is that the draft pair
// enforces them too, and that neither pair accepts two specs for one file.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class DatasetsRouteRoundTripTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-datasets-rt")
    }

    private struct Fixture {
        let assignmentID: String
        let draftID: String
        let cookie: String
        let csrf: String
    }

    /// A course with one published assignment and one unpublished draft, both
    /// bundling `cases.csv` + `notes.txt`, plus an instructor session.
    private func fixture(_ tag: String) async throws -> Fixture {
        let course = APICourse(code: "DSR\(tag)", name: "Datasets Round Trip", enrollmentMode: .auto)
        try await course.save(on: app.db)
        let courseID = try course.requireID()

        let manifest = """
            {"schemaVersion":1,"requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}
            """
        let setupID = "dsr_\(UUID().uuidString.prefix(8))"
        try await makeSetup(id: setupID, manifest: manifest, courseID: courseID)
        let assignment = APIAssignment(
            testSetupID: setupID, title: "Datasets Lab",
            dueAt: nil, isOpen: true, deadlineOverrideActive: false, courseID: courseID)
        try await assignment.save(on: app.db)

        let draftID = "dsrdraft_\(UUID().uuidString.prefix(8))"
        try await makeSetup(id: draftID, manifest: manifest, courseID: courseID)

        let username = "dsr_inst_\(tag)"
        let cookie = try await loginUser(username: username, password: "pw", role: "user", on: app)
        try await promoteToInstructor(username, on: app)
        let (csrf, sessionCookie) = try await csrfFields(
            for: "/instructor/\(assignment.publicID)/edit", cookie: cookie, on: app)
        return Fixture(
            assignmentID: assignment.publicID, draftID: draftID,
            cookie: sessionCookie, csrf: csrf)
    }

    private func makeSetup(id: String, manifest: String, courseID: UUID) async throws {
        let zipPath = app.testSetupsDirectory + id + ".zip"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsr-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("id\n1\n2\n3\n".utf8).write(to: root.appendingPathComponent("cases.csv"))
        try Data("notes".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try writeZipFixture(of: root, to: zipPath)
        let setup = APITestSetup(id: id, manifest: manifest, zipPath: zipPath, courseID: courseID)
        try await setup.save(on: app.db)
    }

    /// GETs the datasets endpoint and returns the decoded specs.
    private func get(_ path: String, _ fx: Fixture) async throws -> [DatasetSpec] {
        var specs: [DatasetSpec] = []
        try await app.asyncTest(
            .GET, path,
            beforeRequest: { req in req.headers.add(name: .cookie, value: fx.cookie) },
            afterResponse: { res in
                #expect(res.status == .ok, "GET \(path) — \(res.body.string)")
                specs = try res.content.decode(DatasetsResponse.self).datasets
            })
        return specs
    }

    /// PUTs a raw JSON body and returns the response (status + body) for the
    /// caller to assert on.
    @discardableResult
    private func put(
        _ path: String, _ fx: Fixture, body: String, expect expected: HTTPStatus, _ note: Comment
    ) async throws -> String {
        var responseBody = ""
        try await app.asyncTest(
            .PUT, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: fx.cookie)
                req.headers.add(name: "x-csrf-token", value: fx.csrf)
                req.headers.contentType = .json
                req.body = ByteBuffer(string: body)
            },
            afterResponse: { res in
                #expect(res.status == expected, "\(note) — got \(res.status): \(res.body.string)")
                responseBody = res.body.string
            })
        return responseBody
    }

    // MARK: - Published: GET → PUT → GET

    @Test func publishedDatasetsRoundTrip() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("p")
            let path = "/instructor/\(fx.assignmentID)/datasets"

            #expect(try await get(path, fx).isEmpty, "an assignment starts with no datasets")

            // Mark.
            let marked = try await put(
                path, fx, body: #"{"datasets":[{"file":"cases.csv","kind":"rowSample","sampleSize":25}]}"#,
                expect: .ok, "marking a bundled file is accepted")
            #expect(marked.contains("cases.csv"), "the PUT echoes the stored state back")

            var stored = try await get(path, fx)
            #expect(stored.count == 1)
            #expect(stored.first?.file == "cases.csv")
            #expect(stored.first?.sampleSize == 25)
            #expect(stored.first?.kind == .rowSample)

            // Change the sample size — the whole array is the payload.
            try await put(
                path, fx, body: #"{"datasets":[{"file":"cases.csv","kind":"rowSample","sampleSize":40}]}"#,
                expect: .ok, "re-PUTting the same file changes its sample size")
            stored = try await get(path, fx)
            #expect(stored.count == 1, "a re-PUT replaces rather than appends")
            #expect(stored.first?.sampleSize == 40)

            // Clear.
            try await put(path, fx, body: #"{"datasets":[]}"#, expect: .ok, "an empty array clears every mark")
            #expect(try await get(path, fx).isEmpty)
        }
    }

    @Test func publishedDatasetsPutPreservesTheRestOfTheManifest() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("m")
            try await put(
                "/instructor/\(fx.assignmentID)/datasets", fx,
                body: #"{"datasets":[{"file":"cases.csv","sampleSize":3}]}"#,
                expect: .ok, "marking a bundled file is accepted")

            let assignment = try #require(
                try await assignmentByPublicID(fx.assignmentID, on: app.db))
            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            let props = try #require(setup.decodedManifest())
            #expect(props.datasets.first?.file == "cases.csv")
            #expect(props.timeLimitSeconds == 10, "the write splices, it does not rebuild")
            #expect(props.schemaVersion == 1)
        }
    }

    // MARK: - Draft: the create page's pair

    @Test func draftDatasetsRoundTrip() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("d")
            let path = "/instructor/new/draft/datasets?draftID=\(fx.draftID)"

            #expect(try await get(path, fx).isEmpty, "a draft starts with no datasets")

            try await put(
                path, fx, body: #"{"datasets":[{"file":"cases.csv","kind":"rowSample","sampleSize":12}]}"#,
                expect: .ok, "a draft accepts a mark on a bundled file")

            let stored = try await get(path, fx)
            #expect(stored.count == 1)
            #expect(stored.first?.file == "cases.csv")
            #expect(stored.first?.sampleSize == 12)

            try await put(path, fx, body: #"{"datasets":[]}"#, expect: .ok, "a draft mark can be cleared")
            #expect(try await get(path, fx).isEmpty)
        }
    }

    @Test func draftDatasetsEnforceTheSharedValidation() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("v")
            let path = "/instructor/new/draft/datasets?draftID=\(fx.draftID)"

            try await put(
                path, fx, body: #"{"datasets":[{"file":"../../.worker-secret","sampleSize":2}]}"#,
                expect: .badRequest, "the draft pair rejects a traversal path too")
            try await put(
                path, fx, body: #"{"datasets":[{"file":"absent.csv","sampleSize":2}]}"#,
                expect: .badRequest, "the draft pair rejects a file the zip does not bundle")
            try await put(
                path, fx, body: #"{"datasets":[{"file":"cases.csv","sampleSize":0}]}"#,
                expect: .badRequest, "the draft pair rejects a non-positive sample size")
            #expect(try await get(path, fx).isEmpty, "a rejected write stores nothing")
        }
    }

    @Test func draftDatasetsRequireADraftID() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("n")
            try await put(
                "/instructor/new/draft/datasets", fx,
                body: #"{"datasets":[]}"#,
                expect: .badRequest, "the draft pair is addressed by draftID")
        }
    }

    // MARK: - The control the Files panel renders from those specs
    //
    // What the round trip cannot show is that the stored spec reaches the
    // markup. These GET the two authoring pages and read the control back out
    // of the HTML: a checked toggle and the saved row count on the marked file,
    // an unchecked toggle and a hidden field on the plain one.

    private func page(_ path: String, _ fx: Fixture) async throws -> String {
        var html = ""
        try await app.asyncTest(
            .GET, path,
            beforeRequest: { req in req.headers.add(name: .cookie, value: fx.cookie) },
            afterResponse: { res in
                #expect(res.status == .ok, "GET \(path) — \(res.status)")
                html = res.body.string
            })
        return html
    }

    /// The support-file row's markup, from its `data-support-file` anchor to
    /// the end of that table row.
    private func rowMarkup(for filename: String, in html: String) throws -> String {
        let anchor = "data-support-file=\"\(filename)\""
        let start = try #require(html.range(of: anchor), "no row for \(filename)")
        let rest = html[start.upperBound...]
        let end = try #require(rest.range(of: "</tr>"), "row for \(filename) never closes")
        return String(rest[..<end.lowerBound])
    }

    @Test func editPageRendersTheDatasetControlFromTheStoredSpec() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("e")
            try await put(
                "/instructor/\(fx.assignmentID)/datasets", fx,
                body: #"{"datasets":[{"file":"cases.csv","kind":"rowSample","sampleSize":25}]}"#,
                expect: .ok, "marking a bundled file is accepted")

            let html = try await page("/instructor/\(fx.assignmentID)/edit", fx)
            let marked = try rowMarkup(for: "cases.csv", in: html)
            #expect(marked.contains("js-dataset-toggle"))
            #expect(marked.contains("checked"), "a marked file renders a checked toggle")
            #expect(marked.contains("value=\"25\""), "and its stored row count")
            #expect(marked.contains("hidden") == false, "and shows the row-count field")

            let plain = try rowMarkup(for: "notes.txt", in: html)
            #expect(plain.contains("js-dataset-toggle"))
            #expect(plain.contains("checked") == false, "an unmarked file renders an unchecked toggle")
            #expect(plain.contains("hidden"), "and keeps its row-count field hidden")
        }
    }

    @Test func createPageRendersTheDatasetControlFromTheStoredSpec() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("c")
            try await put(
                "/instructor/new/draft/datasets?draftID=\(fx.draftID)", fx,
                body: #"{"datasets":[{"file":"cases.csv","kind":"rowSample","sampleSize":8}]}"#,
                expect: .ok, "a draft accepts a mark on a bundled file")

            let html = try await page("/instructor/new?draftID=\(fx.draftID)", fx)
            let marked = try rowMarkup(for: "cases.csv", in: html)
            #expect(marked.contains("js-dataset-toggle"))
            #expect(marked.contains("checked"))
            #expect(marked.contains("value=\"8\""))
            #expect(marked.contains("hidden") == false)

            let plain = try rowMarkup(for: "notes.txt", in: html)
            #expect(plain.contains("checked") == false)
            #expect(plain.contains("hidden"))
        }
    }

    // MARK: - Two specs for one file are incoherent on either pair

    @Test func duplicateSpecsForOneFileAreRejected() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("x")
            let body = #"""
                {"datasets":[{"file":"cases.csv","sampleSize":5},{"file":"cases.csv","sampleSize":9}]}
                """#
            try await put(
                "/instructor/\(fx.assignmentID)/datasets", fx, body: body,
                expect: .badRequest, "one file cannot carry two sample sizes")
            try await put(
                "/instructor/new/draft/datasets?draftID=\(fx.draftID)", fx, body: body,
                expect: .badRequest, "the draft pair agrees")
        }
    }
}
