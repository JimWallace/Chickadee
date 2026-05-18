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

import Fluent
import Foundation
import Testing
import XCTVapor

@testable import chickadee_server

@Suite(.serialized) final class BrowserRunnerRoutesTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-br")
    }

    // MARK: - Helpers

    private func loginAsStudent() async throws -> String {
        return try await loginUser(username: "student1", password: "pass", role: "student", on: app)
    }

    /// Creates a test setup with a given manifest JSON and a small dummy zip.
    private func insertSetup(manifest: String) async throws -> String {
        let setupID = "setup_\(UUID().uuidString.lowercased().prefix(8))"
        let zipPath = app.testSetupsDirectory + "\(setupID).zip"
        // Write a minimal valid ZIP (end-of-central-directory record only).
        let emptyZip = Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))
        try emptyZip.write(to: URL(fileURLWithPath: zipPath))

        let course = APICourse(code: "BR101", name: "Browser Runner Course", enrollmentMode: .auto)
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

    @discardableResult
    private func insertAssignment(
        testSetupID: String,
        isOpen: Bool,
        dueAt: Date? = nil,
        deadlineOverrideActive: Bool = false
    ) async throws -> APIAssignment {
        let setupOptional = try await APITestSetup.find(testSetupID, on: app.db)
        #expect(setupOptional != nil)
        let setup = setupOptional!
        let assignment = APIAssignment(
            testSetupID: testSetupID,
            title: "Browser Assignment",
            dueAt: dueAt,
            isOpen: isOpen,
            deadlineOverrideActive: deadlineOverrideActive,
            courseID: setup.courseID
        )
        try await assignment.save(on: app.db)
        return assignment
    }

    // MARK: - Manifest endpoint

    @Test func manifestRequiresAuthentication() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSetup(manifest: simpleManifest())

            try await app.asyncTest(
                .GET, "/api/v1/browser-runner/testsetups/\(setupID)/manifest",
                afterResponse: { res in
                    #expect(
                        res.status == .unauthorized || res.status == .seeOther,
                        "unauthenticated manifest request should be rejected, got \(res.status)")
                })

        }
    }

    @Test func manifestReturnsJSON() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSetup(manifest: simpleManifest())
            let cookie = try await loginAsStudent()

            try await app.asyncTest(
                .GET, "/api/v1/browser-runner/testsetups/\(setupID)/manifest",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let ct = res.headers.first(name: .contentType) ?? ""
                    #expect(
                        ct.contains("application/json"),
                        "manifest endpoint must return application/json, got: \(ct)")
                })

        }
    }

    @Test func manifestBodyIsParseable() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSetup(manifest: simpleManifest())
            let cookie = try await loginAsStudent()

            try await app.asyncTest(
                .GET, "/api/v1/browser-runner/testsetups/\(setupID)/manifest",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let data = Data(res.body.readableBytesView)
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    #expect(json != nil, "manifest body must be valid JSON object")
                    #expect(json?["testSuites"] != nil, "manifest must contain 'testSuites' key")
                    #expect(json?["gradingMode"] != nil, "manifest must contain 'gradingMode' key")
                })

        }
    }

    /// Regression for #105: the manifest must include the `dependsOn` arrays
    /// that the browser runner reads before executing each test script.
    /// A missing or malformed `dependsOn` field caused JS errors in older
    /// versions of browser-runner.js.
    @Test func manifestIncludesDependsOnArrays() async throws {
        try await withApp(app) { _ in
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
            let cookie = try await loginAsStudent()

            try await app.asyncTest(
                .GET, "/api/v1/browser-runner/testsetups/\(setupID)/manifest",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let data = Data(res.body.readableBytesView)
                    let json = try #require(
                        JSONSerialization.jsonObject(with: data) as? [String: Any])
                    let suites = try #require(json["testSuites"] as? [[String: Any]])
                    #expect(suites.count == 3)

                    // First entry has no dependsOn — either absent or empty array is fine.
                    let first = suites[0]
                    if let deps = first["dependsOn"] {
                        let arr = try #require(deps as? [Any])
                        #expect(arr.isEmpty, "first entry should have empty dependsOn")
                    }

                    // Second and third entries must have dependsOn = ["test_build.py"]
                    for idx in [1, 2] {
                        let entry = suites[idx]
                        let deps = try #require(
                            entry["dependsOn"] as? [String],
                            "suites[\(idx)] must have a dependsOn string array")
                        #expect(deps == ["test_build.py"], "suites[\(idx)] dependsOn should be [\"test_build.py\"]")
                    }
                })

        }
    }

    @Test func manifestReturns404ForUnknownSetup() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent()

            try await app.asyncTest(
                .GET, "/api/v1/browser-runner/testsetups/setup_doesnotexist/manifest",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })

        }
    }

    // MARK: - Download endpoint

    @Test func downloadRequiresAuthentication() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSetup(manifest: simpleManifest())

            try await app.asyncTest(
                .GET, "/api/v1/browser-runner/testsetups/\(setupID)/download",
                afterResponse: { res in
                    #expect(
                        res.status == .unauthorized || res.status == .seeOther,
                        "unauthenticated download should be rejected, got \(res.status)")
                })

        }
    }

    @Test func downloadSucceedsForAuthenticatedStudent() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSetup(manifest: simpleManifest())
            let cookie = try await loginAsStudent()

            try await app.asyncTest(
                .GET, "/api/v1/browser-runner/testsetups/\(setupID)/download",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok, "authenticated student must be able to download test setup zip")
                })

        }
    }

    @Test func downloadReturns404ForUnknownSetup() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent()

            try await app.asyncTest(
                .GET, "/api/v1/browser-runner/testsetups/setup_missing/download",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })

        }
    }

    // MARK: - Full round-trip: dependency-skipped outcomes stored correctly

    /// Regression for #105: when the browser runner skips a test because its
    /// prerequisite failed, the resulting TestOutcomeCollection (with the
    /// skipped outcome recorded as `fail`) must be accepted and stored by the
    /// server without error.
    @Test func browserResultAcceptsDependencySkippedOutcomes() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSetup(manifest: simpleManifest())
            _ = try await insertAssignment(testSetupID: setupID, isOpen: true)
            let cookie = try await loginAsStudent()
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
            let nb = minimalNotebook()

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
            try await app.asyncTest(
                .POST, "/api/v1/submissions/browser-result",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.body = .init(
                        buffer: multipartBody(
                            boundary: "dep-test-boundary",
                            fields: [("_csrf", csrf), ("collection", collection), ("testSetupID", setupID)],
                            file: ("notebook", "notebook.ipynb", nb)
                        ))
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart", subType: "form-data",
                        parameters: ["boundary": "dep-test-boundary"])
                },
                afterResponse: { res in
                    #expect(
                        res.status == .ok,
                        "server must accept collection with dependency-skipped outcomes, body: \(res.body.string)")
                    if let json = try? JSONSerialization.jsonObject(
                        with: Data(res.body.readableBytesView)) as? [String: String]
                    {
                        submissionID = json["submissionID"] ?? ""
                    }
                })

            #expect(submissionID.isEmpty == false, "should have received a submissionID")

            // Verify the result was stored with both outcomes.
            let result = try await APIResult.query(on: app.db)
                .filter(\.$submissionID == submissionID)
                .first()
            #expect(result != nil, "a result record should be stored for the submission")
            #expect(
                result?.collectionJSON.contains("prerequisite") == true,
                "stored result JSON should contain the dependency-skip message")

        }
    }

    @Test func runnerSubmitRejectsBrowserGradedAssignments() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSetup(manifest: simpleManifest())
            _ = try await insertAssignment(testSetupID: setupID, isOpen: true)
            let cookie = try await loginAsStudent()
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
            let nb = minimalNotebook()

            try await app.asyncTest(
                .POST, "/api/v1/submissions/runner-submit",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.body = .init(
                        buffer: multipartBody(
                            boundary: "runner-submit-browser-boundary",
                            fields: [("_csrf", csrf), ("testSetupID", setupID), ("filename", "submission.ipynb")],
                            file: ("notebook", "submission.ipynb", nb)
                        ))
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart", subType: "form-data",
                        parameters: ["boundary": "runner-submit-browser-boundary"])
                },
                afterResponse: { res in
                    #expect(res.status == .badRequest)
                    #expect(
                        res.body.string.contains(
                            "Browser-graded assignments must be submitted through the browser runner."),
                        "expected browser-mode runner-submit requests to be rejected with a clear error"
                    )
                })

            let allSubs = try await APISubmission.query(on: app.db).all()
            #expect(allSubs.isEmpty, "runner-submit should not create queued submissions for browser-mode setups")

        }
    }

    @Test func browserResultRejectsOverdueAssignmentsAndClosesThem() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSetup(manifest: simpleManifest())
            let assignment = try await insertAssignment(
                testSetupID: setupID,
                isOpen: true,
                dueAt: Date().addingTimeInterval(-60)
            )
            let cookie = try await loginAsStudent()
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
            let nb = minimalNotebook()
            let collection = """
                {"submissionID":"","testSetupID":"\(setupID)","attemptNumber":1,"buildStatus":"passed","compilerOutput":null,"outcomes":[],"totalTests":0,"passCount":0,"failCount":0,"errorCount":0,"timeoutCount":0,"executionTimeMs":0,"runnerVersion":"browser-wasm-runner/1.0","timestamp":"2026-01-01T00:00:00Z"}
                """

            try await app.asyncTest(
                .POST, "/api/v1/submissions/browser-result",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.body = .init(
                        buffer: multipartBody(
                            boundary: "browser-result-overdue-boundary",
                            fields: [("_csrf", csrf), ("collection", collection), ("testSetupID", setupID)],
                            file: ("notebook", "notebook.ipynb", nb)
                        ))
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart", subType: "form-data",
                        parameters: ["boundary": "browser-result-overdue-boundary"])
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                    #expect(res.body.string.contains("closed"))
                })

            let refreshedOptional = try await APIAssignment.find(assignment.id, on: app.db)
            #expect(refreshedOptional != nil)
            let refreshed = refreshedOptional!
            #expect(refreshed.isOpen == false)

        }
    }

    @Test func runnerSubmitRejectsOverdueAssignmentsAndClosesThem() async throws {
        try await withApp(app) { _ in
            let manifest = """
                {
                  "schemaVersion": 1,
                  "gradingMode": "worker",
                  "requiredFiles": [],
                  "testSuites": [
                    { "tier": "public", "script": "test_public.py" }
                  ],
                  "timeLimitSeconds": 10,
                  "makefile": null
                }
                """
            let setupID = try await insertSetup(manifest: manifest)
            let assignment = try await insertAssignment(
                testSetupID: setupID,
                isOpen: true,
                dueAt: Date().addingTimeInterval(-60)
            )
            let cookie = try await loginAsStudent()
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
            let nb = minimalNotebook()

            try await app.asyncTest(
                .POST, "/api/v1/submissions/runner-submit",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.body = .init(
                        buffer: multipartBody(
                            boundary: "runner-submit-overdue-boundary",
                            fields: [("_csrf", csrf), ("testSetupID", setupID), ("filename", "submission.ipynb")],
                            file: ("notebook", "submission.ipynb", nb)
                        ))
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart", subType: "form-data",
                        parameters: ["boundary": "runner-submit-overdue-boundary"])
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                    #expect(res.body.string.contains("closed"))
                })

            let refreshedOptional = try await APIAssignment.find(assignment.id, on: app.db)
            #expect(refreshedOptional != nil)
            let refreshed = refreshedOptional!
            #expect(refreshed.isOpen == false)

        }
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
