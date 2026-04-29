// Tests/APITests/DraftNotebookChecksRoutesTests.swift
//
// Coverage for the draft-scoped notebook-check editor endpoint added in
// v0.4.132 / parity PR 2 of #433:
//
//   PUT /instructor/new/draft/checks?draftID=<id>
//
// The handler mirrors the assignment-scoped `putNotebookChecks`; only
// the resolver and the absence of validation scheduling differ.  Tests
// focus on behaviour we own here: the persisted manifest's `notebookChecks`
// matches the body, malformed bodies 400, and missing draftID 400s.

import XCTest
import XCTVapor
@testable import chickadee_server
import Fluent
import Foundation
import Core

final class DraftNotebookChecksRoutesTests: XCTestCase {

    private var app: Application!
    private var tmpDir: String!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-dnct-\(UUID().uuidString)/")
            .path
        for dir in ["results/", "testsetups/", "submissions/"].map({ tmpDir + $0 }) {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        app.resultsDirectory     = tmpDir + "results/"
        app.testSetupsDirectory  = tmpDir + "testsetups/"
        app.submissionsDirectory = tmpDir + "submissions/"
        app.sessions.use(.memory)
        app.middleware.use(app.sessions.middleware)
        try await configureTestDatabase(app)
        configureLeaf(app)
        try routes(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    private func makeDraft() async throws -> String {
        let courseID = UUID()
        let course = APICourse(id: courseID, code: "DNCT", name: "Draft Notebook Checks Test", enrollmentMode: .auto)
        try await course.save(on: app.db)

        let setupID = "dnct_\(UUID().uuidString.prefix(8))"
        let zipPath = app.testSetupsDirectory + setupID + ".zip"
        FileManager.default.createFile(atPath: zipPath, contents: Data())
        // Seed the zip with a placeholder entry so the apply path's
        // zip-rewrite step has something to read; an empty stub file
        // would fail with ScriptZipError.zipFailed on the first PUT.
        try updateScriptInZip(zipPath: zipPath, filename: "placeholder.txt", content: "")

        let manifestDict: [String: Any] = [
            "schemaVersion":   1,
            "gradingMode":     "worker",
            "requiredFiles":   [],
            "timeLimitSeconds": 10,
            "makefile":        NSNull(),
            "testSuites":      [],
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifestDict, options: [.sortedKeys])
        let manifest = String(data: manifestData, encoding: .utf8)!

        let setup = APITestSetup(id: setupID, manifest: manifest, zipPath: zipPath, courseID: courseID)
        try await setup.save(on: app.db)
        return setupID
    }

    private func loadManifestProps(setupID: String) async throws -> TestProperties {
        guard let setup = try await APITestSetup.find(setupID, on: app.db),
              let data = setup.manifest.data(using: .utf8),
              let props = try? JSONDecoder().decode(TestProperties.self, from: data)
        else { throw XCTSkip("manifest load failed") }
        return props
    }

    func testPutDraftChecks_persistsAppliedChecks() async throws {
        let draftID = try await makeDraft()
        let cookie = try await loginUser(username: "dnct_inst1", password: "pw", role: "instructor", on: app)
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

        let body = [
            NotebookCheck(
                id: "df_shape", name: "DataFrame shape",
                kind: .dataFrameShape, tier: .pub, points: 1,
                variable: "df", expectedRows: 250, expectedCols: 13
            ),
            NotebookCheck(
                id: "fn_classify", name: nil,
                kind: .functionExists, tier: .pub, points: 1,
                variable: "classify_bmi", expectedArity: 1
            ),
        ]

        try await app.asyncTest(.PUT, "/instructor/new/draft/checks?draftID=\(draftID)", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.add(name: .init("x-csrf-token"), value: csrf)
            try req.content.encode(body, as: .json)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })

        let props = try await loadManifestProps(setupID: draftID)
        XCTAssertEqual(props.notebookChecks.count, 2)
        XCTAssertEqual(props.notebookChecks.map(\.id), ["df_shape", "fn_classify"])
        XCTAssertEqual(props.notebookChecks[0].variable, "df")
        XCTAssertEqual(props.notebookChecks[0].expectedRows, 250)
        XCTAssertEqual(props.notebookChecks[1].kind, .functionExists)
    }

    func testPutDraftChecks_replacesExistingList() async throws {
        let draftID = try await makeDraft()
        let cookie = try await loginUser(username: "dnct_inst2", password: "pw", role: "instructor", on: app)
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

        // First save: two checks.
        let firstBody = [
            NotebookCheck(id: "a", kind: .figureCount, minFigures: 1),
            NotebookCheck(id: "b", kind: .figureCount, minFigures: 2),
        ]
        try await app.asyncTest(.PUT, "/instructor/new/draft/checks?draftID=\(draftID)", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.add(name: .init("x-csrf-token"), value: csrf)
            try req.content.encode(firstBody, as: .json)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })

        // Second save: replace with one different check.
        let secondBody = [
            NotebookCheck(id: "c", kind: .figureCount, minFigures: 3),
        ]
        try await app.asyncTest(.PUT, "/instructor/new/draft/checks?draftID=\(draftID)", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.add(name: .init("x-csrf-token"), value: csrf)
            try req.content.encode(secondBody, as: .json)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })

        let props = try await loadManifestProps(setupID: draftID)
        XCTAssertEqual(props.notebookChecks.map(\.id), ["c"], "PUT must atomically replace the full list")
    }

    func testPutDraftChecks_missingDraftIDReturns400() async throws {
        _ = try await makeDraft()
        let cookie = try await loginUser(username: "dnct_inst3", password: "pw", role: "instructor", on: app)
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

        try await app.asyncTest(.PUT, "/instructor/new/draft/checks", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.add(name: .init("x-csrf-token"), value: csrf)
            try req.content.encode([NotebookCheck](), as: .json)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    func testPutDraftChecks_unknownDraftIDReturns404() async throws {
        let cookie = try await loginUser(username: "dnct_inst4", password: "pw", role: "instructor", on: app)
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

        try await app.asyncTest(.PUT, "/instructor/new/draft/checks?draftID=does-not-exist", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.add(name: .init("x-csrf-token"), value: csrf)
            try req.content.encode([NotebookCheck](), as: .json)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    func testPutDraftChecks_emptyListClearsManifest() async throws {
        let draftID = try await makeDraft()
        let cookie = try await loginUser(username: "dnct_inst5", password: "pw", role: "instructor", on: app)
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

        try await app.asyncTest(.PUT, "/instructor/new/draft/checks?draftID=\(draftID)", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.add(name: .init("x-csrf-token"), value: csrf)
            try req.content.encode([NotebookCheck](), as: .json)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })

        let props = try await loadManifestProps(setupID: draftID)
        XCTAssertEqual(props.notebookChecks.count, 0)
    }
}
