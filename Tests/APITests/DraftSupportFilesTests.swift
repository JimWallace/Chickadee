// Tests/APITests/DraftSupportFilesTests.swift
//
// Coverage for the draft-scoped support-file plumbing added in
// v0.4.132 / parity PR 3 of #433:
//
//   GET    /instructor/new/draft/files/item?draftID=<id>&name=<filename>
//
// The upload (POST /draft/scripts) and delete (DELETE /draft/scripts/:f)
// endpoints already existed and accept `tier: "support"`; we cover the
// new download endpoint here, including the upload-then-download cycle
// that the create-page UI relies on.

import XCTest
import XCTVapor
@testable import chickadee_server
import Fluent
import Foundation
import Core

final class DraftSupportFilesTests: XCTestCase {

    private var app: Application!
    private var tmpDir: String!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-dsft-\(UUID().uuidString)/")
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

    // Creates a course + draft test setup with a real zip file containing
    // an optional support file.  Returns the setupID for use as ?draftID=.
    private func makeDraft(withSupportFile: (name: String, contents: String)? = nil) async throws -> String {
        let courseID = UUID()
        let course = APICourse(id: courseID, code: "DSFT", name: "Draft Support Files Test", enrollmentMode: .auto)
        try await course.save(on: app.db)

        let setupID = "dsft_\(UUID().uuidString.prefix(8))"
        let zipPath = app.testSetupsDirectory + setupID + ".zip"
        // Empty zip first; updateScriptInZip handles the create-from-empty case.
        FileManager.default.createFile(atPath: zipPath, contents: Data())

        if let f = withSupportFile {
            try updateScriptInZip(zipPath: zipPath, filename: f.name, content: f.contents)
        }

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

    // MARK: - GET /instructor/new/draft/files/item

    func testDownloadDraftItem_returnsFileBytes() async throws {
        let payload = "name,age\nAlice,30\nBob,25\n"
        let draftID = try await makeDraft(withSupportFile: (name: "fixtures.csv", contents: payload))
        let cookie = try await loginUser(username: "dsft_inst1", password: "pw", role: "instructor", on: app)
        let (_, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

        try await app.asyncTest(.GET, "/instructor/new/draft/files/item?draftID=\(draftID)&name=fixtures.csv", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.body.string, payload)
        })
    }

    func testDownloadDraftItem_unknownFileReturns404() async throws {
        let draftID = try await makeDraft(withSupportFile: (name: "fixtures.csv", contents: "x"))
        let cookie = try await loginUser(username: "dsft_inst2", password: "pw", role: "instructor", on: app)
        let (_, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

        try await app.asyncTest(.GET, "/instructor/new/draft/files/item?draftID=\(draftID)&name=missing.csv", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    func testDownloadDraftItem_pathTraversalRejected() async throws {
        let draftID = try await makeDraft(withSupportFile: (name: "fixtures.csv", contents: "x"))
        let cookie = try await loginUser(username: "dsft_inst3", password: "pw", role: "instructor", on: app)
        let (_, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

        try await app.asyncTest(.GET, "/instructor/new/draft/files/item?draftID=\(draftID)&name=..%2F..%2Fetc%2Fpasswd", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    func testDownloadDraftItem_missingDraftIDReturns400() async throws {
        _ = try await makeDraft(withSupportFile: (name: "fixtures.csv", contents: "x"))
        let cookie = try await loginUser(username: "dsft_inst4", password: "pw", role: "instructor", on: app)
        let (_, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

        try await app.asyncTest(.GET, "/instructor/new/draft/files/item?name=fixtures.csv", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    // MARK: - End-to-end: upload via /draft/scripts, download via /draft/files/item

    func testUploadThenDownload_supportFile_roundTripsContent() async throws {
        let draftID = try await makeDraft()
        let cookie = try await loginUser(username: "dsft_inst5", password: "pw", role: "instructor", on: app)
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

        // Upload via the existing draft-scripts endpoint with tier=support.
        struct UploadBody: Content {
            var filename: String
            var content:  String
            var tier:     String
            var isTest:   Bool
        }
        let body = UploadBody(filename: "data.json", content: #"{"k": 1}"#, tier: "support", isTest: false)
        try await app.asyncTest(.POST, "/instructor/new/draft/scripts?draftID=\(draftID)", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.add(name: .init("x-csrf-token"), value: csrf)
            try req.content.encode(body, as: .json)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .created)
        })

        // Download via the new draft files/item endpoint.
        try await app.asyncTest(.GET, "/instructor/new/draft/files/item?draftID=\(draftID)&name=data.json", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.body.string, #"{"k": 1}"#)
        })

        // Confirm the support file is NOT in the manifest's testSuites
        // (the create-page handler filters tier=="support" out of the
        // suite editor; manifest entries would mistakenly run it as a test).
        guard let setup = try await APITestSetup.find(draftID, on: app.db),
              let data = setup.manifest.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return XCTFail("manifest load failed") }
        let entries = dict["testSuites"] as? [[String: Any]] ?? []
        XCTAssertTrue(entries.isEmpty, "Support file uploads must not add a testSuites entry")
    }
}
