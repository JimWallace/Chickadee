// Tests/APITests/BrowserRunnerRoutesTests.swift
//
// Regression tests for issue #105 — browser runner errors on labs.
//
// Covers the two session-authenticated endpoints the browser runner calls
// before executing tests locally in Pyodide:
//
//   GET /api/v1/browser-runner/testsetups/:id/manifest  — test properties JSON
//   GET /api/v1/browser-runner/testsetups/:id/download  — test setup zip
//
// Also covers the submission path with dependency-skipped outcomes to confirm
// the full round-trip works after the dependsOn pre-check was added.

import XCTest
import XCTVapor
@testable import chickadee_server
import FluentSQLiteDriver
import Foundation

final class BrowserRunnerRoutesTests: XCTestCase {

    private var app: Application!
    private var tmpDir: String!

    override func setUp() async throws {
        app = Application(.testing)

        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-br-\(UUID().uuidString)/")
            .path

        for subdir in ["results/", "testsetups/", "submissions/"] {
            try FileManager.default.createDirectory(
                atPath: tmpDir + subdir, withIntermediateDirectories: true)
        }
        app.resultsDirectory     = tmpDir + "results/"
        app.testSetupsDirectory  = tmpDir + "testsetups/"
        app.submissionsDirectory = tmpDir + "submissions/"

        app.sessions.use(.memory)
        app.middleware.use(app.sessions.middleware)

        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateUsers())
        app.migrations.add(CreateCourses())
        app.migrations.add(CreateCourseEnrollments())
        app.migrations.add(CreateTestSetups())
        app.migrations.add(CreateSubmissions())
        app.migrations.add(CreateResults())
        app.migrations.add(CreateAssignments())
        app.migrations.add(CreatePerformanceIndexes())
        app.migrations.add(AddCourseSections())
        app.migrations.add(AddCourseOpenEnrollment())
        try await app.autoMigrate().get()

        try routes(app)
    }

    override func tearDown() async throws {
        app.shutdown()
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    // MARK: - Helpers

    private func loginAsStudent() async throws -> String {
        let hash = try Bcrypt.hash("pass")
        let user = APIUser(username: "student1", passwordHash: hash, role: "student")
        try await user.save(on: app.db)
        var cookie = ""
        try await app.test(.POST, "/login", beforeRequest: { req in
            try req.content.encode(["username": "student1", "password": "pass"],
                                   as: .urlEncodedForm)
        }, afterResponse: { res in
            cookie = res.headers.first(name: .setCookie) ?? ""
        })
        return cookie
    }

    /// Creates a test setup with a given manifest JSON and a small dummy zip.
    private func insertSetup(manifest: String) async throws -> String {
        let setupID = "setup_\(UUID().uuidString.lowercased().prefix(8))"
        let zipPath = tmpDir + "testsetups/\(setupID).zip"
        // Write a minimal valid ZIP (end-of-central-directory record only).
        let emptyZip = Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))
        try emptyZip.write(to: URL(fileURLWithPath: zipPath))

        let course = APICourse(code: "BR101", name: "Browser Runner Course")
        try await course.save(on: app.db)

        let setup = APITestSetup(
            id: setupID,
            manifest: manifest,
            zipPath: zipPath,
            courseID: try course.requireID()
        )
        try await setup.save(on: app.db)
        return setupID
    }

    // MARK: - Manifest endpoint

    func testManifestRequiresAuthentication() async throws {
        let setupID = try await insertSetup(manifest: simpleManifest())

        try await app.test(.GET, "/api/v1/browser-runner/testsetups/\(setupID)/manifest",
            afterResponse: { res in
                XCTAssertTrue(
                    res.status == .unauthorized || res.status == .seeOther,
                    "unauthenticated manifest request should be rejected, got \(res.status)")
            })
    }

    func testManifestReturnsJSON() async throws {
        let setupID = try await insertSetup(manifest: simpleManifest())
        let cookie  = try await loginAsStudent()

        try await app.test(.GET, "/api/v1/browser-runner/testsetups/\(setupID)/manifest",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let ct = res.headers.first(name: .contentType) ?? ""
                XCTAssertTrue(ct.contains("application/json"),
                              "manifest endpoint must return application/json, got: \(ct)")
            })
    }

    func testManifestBodyIsParseable() async throws {
        let setupID = try await insertSetup(manifest: simpleManifest())
        let cookie  = try await loginAsStudent()

        try await app.test(.GET, "/api/v1/browser-runner/testsetups/\(setupID)/manifest",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let data = Data(res.body.readableBytesView)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                XCTAssertNotNil(json, "manifest body must be valid JSON object")
                XCTAssertNotNil(json?["testSuites"], "manifest must contain 'testSuites' key")
                XCTAssertNotNil(json?["gradingMode"], "manifest must contain 'gradingMode' key")
            })
    }

    /// Regression for #105: the manifest must include the `dependsOn` arrays
    /// that the browser runner reads before executing each test script.
    /// A missing or malformed `dependsOn` field caused JS errors in older
    /// versions of browser-runner.js.
    func testManifestIncludesDependsOnArrays() async throws {
        let manifest = """
        {
          "schemaVersion": 1,
          "gradingMode": "browser",
          "requiredFiles": [],
          "testSuites": [
            { "tier": "public",  "script": "test_build.py" },
            { "tier": "public",  "script": "test_unit.py",  "dependsOn": ["test_build.py"] },
            { "tier": "release", "script": "test_extra.py", "dependsOn": ["test_build.py"] }
          ],
          "timeLimitSeconds": 10,
          "makefile": null
        }
        """
        let setupID = try await insertSetup(manifest: manifest)
        let cookie  = try await loginAsStudent()

        try await app.test(.GET, "/api/v1/browser-runner/testsetups/\(setupID)/manifest",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let data = Data(res.body.readableBytesView)
                let json = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: data) as? [String: Any])
                let suites = try XCTUnwrap(json["testSuites"] as? [[String: Any]])
                XCTAssertEqual(suites.count, 3)

                // First entry has no dependsOn — either absent or empty array is fine.
                let first = suites[0]
                if let deps = first["dependsOn"] {
                    let arr = try XCTUnwrap(deps as? [Any])
                    XCTAssertTrue(arr.isEmpty, "first entry should have empty dependsOn")
                }

                // Second and third entries must have dependsOn = ["test_build.py"]
                for idx in [1, 2] {
                    let entry = suites[idx]
                    let deps  = try XCTUnwrap(entry["dependsOn"] as? [String],
                        "suites[\(idx)] must have a dependsOn string array")
                    XCTAssertEqual(deps, ["test_build.py"],
                        "suites[\(idx)] dependsOn should be [\"test_build.py\"]")
                }
            })
    }

    func testManifestReturns404ForUnknownSetup() async throws {
        let cookie = try await loginAsStudent()

        try await app.test(.GET, "/api/v1/browser-runner/testsetups/setup_doesnotexist/manifest",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .notFound)
            })
    }

    // MARK: - Download endpoint

    func testDownloadRequiresAuthentication() async throws {
        let setupID = try await insertSetup(manifest: simpleManifest())

        try await app.test(.GET, "/api/v1/browser-runner/testsetups/\(setupID)/download",
            afterResponse: { res in
                XCTAssertTrue(
                    res.status == .unauthorized || res.status == .seeOther,
                    "unauthenticated download should be rejected, got \(res.status)")
            })
    }

    func testDownloadSucceedsForAuthenticatedStudent() async throws {
        let setupID = try await insertSetup(manifest: simpleManifest())
        let cookie  = try await loginAsStudent()

        try await app.test(.GET, "/api/v1/browser-runner/testsetups/\(setupID)/download",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .ok,
                    "authenticated student must be able to download test setup zip")
            })
    }

    func testDownloadReturns404ForUnknownSetup() async throws {
        let cookie = try await loginAsStudent()

        try await app.test(.GET, "/api/v1/browser-runner/testsetups/setup_missing/download",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .notFound)
            })
    }

    // MARK: - Full round-trip: dependency-skipped outcomes stored correctly

    /// Regression for #105: when the browser runner skips a test because its
    /// prerequisite failed, the resulting TestOutcomeCollection (with the
    /// skipped outcome recorded as `fail`) must be accepted and stored by the
    /// server without error.
    func testBrowserResultAcceptsDependencySkippedOutcomes() async throws {
        let setupID = try await insertSetup(manifest: simpleManifest())
        let cookie  = try await loginAsStudent()
        let nb      = minimalNotebook()

        // Simulate the collection the browser runner produces when test_build
        // fails and test_unit is auto-failed as a dependency skip.
        let collection = """
        {
          "submissionID": "",
          "testSetupID": "\(setupID)",
          "attemptNumber": 1,
          "buildStatus": "passed",
          "compilerOutput": null,
          "outcomes": [
            {
              "testName": "test_build",
              "testClass": null,
              "tier": "public",
              "status": "fail",
              "shortResult": "assertion failed",
              "longResult": null,
              "executionTimeMs": 42,
              "memoryUsageBytes": null,
              "attemptNumber": 1,
              "isFirstPassSuccess": false
            },
            {
              "testName": "test_unit",
              "testClass": null,
              "tier": "public",
              "status": "fail",
              "shortResult": "Skipped: prerequisite 'test_build.py' did not pass",
              "longResult": null,
              "executionTimeMs": 0,
              "memoryUsageBytes": null,
              "attemptNumber": 1,
              "isFirstPassSuccess": false
            }
          ],
          "totalTests": 2,
          "passCount": 0,
          "failCount": 2,
          "errorCount": 0,
          "timeoutCount": 0,
          "executionTimeMs": 42,
          "runnerVersion": "browser-wasm-runner/1.0",
          "timestamp": "2026-01-01T00:00:00Z"
        }
        """

        var submissionID = ""
        try await app.test(.POST, "/api/v1/submissions/browser-result",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                req.body = .init(buffer: multipartBody(
                    boundary: "dep-test-boundary",
                    fields: [("collection", collection), ("testSetupID", setupID)],
                    file: ("notebook", "notebook.ipynb", nb)
                ))
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data",
                    parameters: ["boundary": "dep-test-boundary"])
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .ok,
                    "server must accept collection with dependency-skipped outcomes, body: \(res.body.string)")
                if let json = try? JSONSerialization.jsonObject(
                    with: Data(res.body.readableBytesView)) as? [String: String] {
                    submissionID = json["submissionID"] ?? ""
                }
            })

        XCTAssertFalse(submissionID.isEmpty, "should have received a submissionID")

        // Verify the result was stored with both outcomes.
        let result = try await APIResult.query(on: app.db)
            .filter(\.$submissionID == submissionID)
            .first()
        XCTAssertNotNil(result, "a result record should be stored for the submission")
        XCTAssertTrue(
            result?.collectionJSON.contains("prerequisite") == true,
            "stored result JSON should contain the dependency-skip message")
    }

    // MARK: - Private fixtures

    private func simpleManifest() -> String {
        """
        {
          "schemaVersion": 1,
          "gradingMode": "browser",
          "requiredFiles": [],
          "testSuites": [
            { "tier": "public", "script": "test_public.py" }
          ],
          "timeLimitSeconds": 10,
          "makefile": null
        }
        """
    }

    private func minimalNotebook() -> Data {
        let json = """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[
          {"cell_type":"code","source":["x = 1"],"metadata":{},"outputs":[]}
        ]}
        """
        return json.data(using: .utf8)!
    }

    private func multipartBody(
        boundary: String,
        fields: [(String, String)],
        file: (String, String, Data)
    ) -> ByteBuffer {
        var buf = ByteBufferAllocator().buffer(capacity: 4096)
        for (name, value) in fields {
            buf.writeString("--\(boundary)\r\n")
            buf.writeString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            buf.writeString(value)
            buf.writeString("\r\n")
        }
        let (fieldName, filename, data) = file
        buf.writeString("--\(boundary)\r\n")
        buf.writeString(
            "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n")
        buf.writeString("Content-Type: application/octet-stream\r\n\r\n")
        buf.writeBytes(data)
        buf.writeString("\r\n")
        buf.writeString("--\(boundary)--\r\n")
        return buf
    }
}
