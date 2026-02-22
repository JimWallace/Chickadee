// Tests/APITests/NotebookDownloadTests.swift
//
// Integration tests for Phase 9 student download + offline upload.
//
//   GET  /api/v1/testsetups/:id/assignment         — role-aware filtering
//   GET  /api/v1/testsetups/:id/assignment/download — attachment + title filename
//   POST /api/v1/submissions/browser-result        — merges hidden test cells
//   POST /api/v1/submissions/file                  — merges hidden test cells

import XCTest
import XCTVapor
@testable import chickadee_server
import FluentSQLiteDriver
import Foundation

final class NotebookDownloadTests: XCTestCase {

    private var app: Application!
    private var tmpDir: String!

    // A notebook with 4 cells: public test, secret test, release test, solution.
    private let mixedNotebookJSON = """
    {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[
      {"cell_type":"code","source":["# TEST: pub tier=public\\nassert True"],"metadata":{},"outputs":[]},
      {"cell_type":"code","source":["# TEST: sec tier=secret\\nassert True"],"metadata":{},"outputs":[]},
      {"cell_type":"code","source":["# TEST: rel tier=release\\nassert True"],"metadata":{},"outputs":[]},
      {"cell_type":"code","source":["x = 42"],"metadata":{},"outputs":[]}
    ]}
    """

    override func setUp() async throws {
        app = Application(.testing)

        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-dl-\(UUID().uuidString)/")
            .path

        let dirs = ["results/", "testsetups/", "submissions/"].map { tmpDir + $0 }
        for dir in dirs {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        app.resultsDirectory     = dirs[0]
        app.testSetupsDirectory  = dirs[1]
        app.submissionsDirectory = dirs[2]

        app.sessions.use(.memory)
        app.middleware.use(app.sessions.middleware)

        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateTestSetups())
        app.migrations.add(CreateSubmissions())
        app.migrations.add(CreateResults())
        app.migrations.add(AddAttemptNumberToSubmissions())
        app.migrations.add(AddFilenameToSubmissions())
        app.migrations.add(AddSourceToResults())
        app.migrations.add(CreateUsers())
        app.migrations.add(CreateAssignments())
        app.migrations.add(AddUserIDToSubmissions())
        app.migrations.add(AddNotebookPathToTestSetups())
        try await app.autoMigrate().get()

        try routes(app)
    }

    override func tearDown() async throws {
        app.shutdown()
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    // MARK: - Auth helpers

    private func loginAsInstructor() async throws -> String {
        let hash = try Bcrypt.hash("testpassword")
        let user = APIUser(username: "testinstructor", passwordHash: hash, role: "instructor")
        try await user.save(on: app.db)

        var cookie = ""
        try await app.test(.POST, "/login", beforeRequest: { req in
            try req.content.encode(["username": "testinstructor", "password": "testpassword"],
                                   as: .urlEncodedForm)
        }, afterResponse: { res in
            cookie = res.headers.first(name: .setCookie) ?? ""
        })
        return cookie
    }

    private func loginAsStudent() async throws -> String {
        let hash = try Bcrypt.hash("testpassword")
        let user = APIUser(username: "teststudent", passwordHash: hash, role: "student")
        try await user.save(on: app.db)

        var cookie = ""
        try await app.test(.POST, "/login", beforeRequest: { req in
            try req.content.encode(["username": "teststudent", "password": "testpassword"],
                                   as: .urlEncodedForm)
        }, afterResponse: { res in
            cookie = res.headers.first(name: .setCookie) ?? ""
        })
        return cookie
    }

    // MARK: - Setup helper

    /// Saves a notebook JSON directly as a flat .ipynb file and returns the setup ID.
    private func insertSetupWithNotebook(notebookJSON: String) async throws -> String {
        let setupID      = "setup_test_\(UUID().uuidString.lowercased().prefix(6))"
        let notebookPath = tmpDir + "testsetups/\(setupID).ipynb"
        let manifest = """
        {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}
        """
        // Write a dummy zip (the flat .ipynb takes priority in getAssignment).
        let dummyZipPath = tmpDir + "testsetups/\(setupID).zip"
        try Data().write(to: URL(fileURLWithPath: dummyZipPath))
        try notebookJSON.data(using: .utf8)!.write(to: URL(fileURLWithPath: notebookPath))

        let setup = APITestSetup(id: setupID, manifest: manifest, zipPath: dummyZipPath)
        setup.notebookPath = notebookPath
        try await setup.save(on: app.db)
        return setupID
    }

    // MARK: - GET /api/v1/testsetups/:id/assignment — role-aware filtering

    func testStudentGetsFilteredNotebook() async throws {
        let setupID = try await insertSetupWithNotebook(notebookJSON: mixedNotebookJSON)
        let cookie  = try await loginAsStudent()

        try await app.test(.GET, "/api/v1/testsetups/\(setupID)/assignment",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let body = res.body.string
                XCTAssertFalse(body.contains("tier=secret"),  "secret cell must be stripped for students")
                XCTAssertFalse(body.contains("tier=release"), "release cell must be stripped for students")
                XCTAssertTrue(body.contains("tier=public"),   "public cell must be present for students")
                XCTAssertTrue(body.contains("x = 42"),        "solution cell must be present")
            })
    }

    func testInstructorGetsFullNotebook() async throws {
        let setupID = try await insertSetupWithNotebook(notebookJSON: mixedNotebookJSON)
        let cookie  = try await loginAsInstructor()

        try await app.test(.GET, "/api/v1/testsetups/\(setupID)/assignment",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let body = res.body.string
                XCTAssertTrue(body.contains("tier=secret"),  "secret cell must be present for instructors")
                XCTAssertTrue(body.contains("tier=release"), "release cell must be present for instructors")
                XCTAssertTrue(body.contains("tier=public"),  "public cell must be present for instructors")
                XCTAssertTrue(body.contains("x = 42"),       "solution cell must be present")
            })
    }

    // MARK: - GET /api/v1/testsetups/:id/assignment/download

    func testDownloadStripsHiddenCells() async throws {
        let setupID = try await insertSetupWithNotebook(notebookJSON: mixedNotebookJSON)
        let cookie  = try await loginAsStudent()

        try await app.test(.GET, "/api/v1/testsetups/\(setupID)/assignment/download",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let body = res.body.string
                XCTAssertFalse(body.contains("tier=secret"),  "secret cell must not appear in download")
                XCTAssertFalse(body.contains("tier=release"), "release cell must not appear in download")
                XCTAssertTrue(body.contains("tier=public"),   "public cell must appear in download")
            })
    }

    func testDownloadContentDispositionHeader() async throws {
        let setupID = try await insertSetupWithNotebook(notebookJSON: mixedNotebookJSON)
        let cookie  = try await loginAsStudent()

        try await app.test(.GET, "/api/v1/testsetups/\(setupID)/assignment/download",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let cd = res.headers.first(name: .contentDisposition) ?? ""
                XCTAssertTrue(cd.hasPrefix("attachment"), "response must have attachment disposition, got: \(cd)")
            })
    }

    func testDownloadFilenameUsesTitle() async throws {
        let setupID = try await insertSetupWithNotebook(notebookJSON: mixedNotebookJSON)
        let cookie  = try await loginAsStudent()

        // Create an assignment record with a title.
        let a = APIAssignment(testSetupID: setupID, title: "Lab 1 Warmup", dueAt: nil, isOpen: true)
        try await a.save(on: app.db)

        try await app.test(.GET, "/api/v1/testsetups/\(setupID)/assignment/download",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let cd = res.headers.first(name: .contentDisposition) ?? ""
                XCTAssertTrue(cd.contains("Lab 1 Warmup.ipynb"),
                              "filename should be assignment title, got: \(cd)")
            })
    }

    func testDownloadFilenameFallsBackToSetupID() async throws {
        let setupID = try await insertSetupWithNotebook(notebookJSON: mixedNotebookJSON)
        let cookie  = try await loginAsStudent()
        // No assignment record — filename falls back to setupID.

        try await app.test(.GET, "/api/v1/testsetups/\(setupID)/assignment/download",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let cd = res.headers.first(name: .contentDisposition) ?? ""
                XCTAssertTrue(cd.contains("\(setupID).ipynb"),
                              "filename should fall back to setupID, got: \(cd)")
            })
    }

    func testUnauthenticatedCannotDownload() async throws {
        let setupID = try await insertSetupWithNotebook(notebookJSON: mixedNotebookJSON)

        try await app.test(.GET, "/api/v1/testsetups/\(setupID)/assignment/download",
            afterResponse: { res in
                // Should redirect to login or return 401.
                XCTAssertTrue(res.status == .unauthorized || res.status == .seeOther,
                              "unauthenticated download should be rejected, got \(res.status)")
            })
    }

    func testStudentCannotUploadTestSetup() async throws {
        let cookie = try await loginAsStudent()

        // POST to /api/v1/testsetups as a student should return 403.
        try await app.test(.POST, "/api/v1/testsetups",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                // Minimal multipart — will be rejected before content is parsed.
                req.headers.contentType = .formData
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .forbidden)
            })
    }

    // MARK: - POST /api/v1/submissions/browser-result — merge hidden test cells

    func testBrowserSubmitMergesTestCells() async throws {
        let setupID = try await insertSetupWithNotebook(notebookJSON: mixedNotebookJSON)
        let cookie  = try await loginAsStudent()

        // Simulate the student's notebook: only the public cell + solution cell
        // (as if they downloaded the filtered version).
        let studentNotebookJSON = """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[
          {"cell_type":"code","source":["# TEST: pub tier=public\\nassert True"],"metadata":{},"outputs":[]},
          {"cell_type":"code","source":["x = 99"],"metadata":{},"outputs":[]}
        ]}
        """
        let studentNotebookData = studentNotebookJSON.data(using: .utf8)!

        // Build a minimal valid TestOutcomeCollection JSON.
        let collectionJSON = """
        {"submissionID":"","testSetupID":"\(setupID)","attemptNumber":1,
         "buildStatus":"passed","compilerOutput":null,"outcomes":[],
         "totalTests":0,"passCount":0,"failCount":0,"errorCount":0,"timeoutCount":0,
         "executionTimeMs":0,"runnerVersion":"browser-pyodide/1.0",
         "timestamp":"2026-01-01T00:00:00Z"}
        """

        var savedSubID = ""

        try await app.test(.POST, "/api/v1/submissions/browser-result",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                // Build multipart body.
                var body = ByteBufferAllocator().buffer(capacity: 1024)
                let boundary = "TestBoundary12345"
                req.headers.contentType = HTTPMediaType(type: "multipart", subType: "form-data",
                                                         parameters: ["boundary": boundary])

                func appendPart(name: String, value: String) {
                    body.writeString("--\(boundary)\r\n")
                    body.writeString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
                    body.writeString(value)
                    body.writeString("\r\n")
                }
                func appendFilePart(name: String, filename: String, data: Data) {
                    body.writeString("--\(boundary)\r\n")
                    body.writeString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
                    body.writeString("Content-Type: application/json\r\n\r\n")
                    body.writeBytes(data)
                    body.writeString("\r\n")
                }

                appendPart(name: "collection",  value: collectionJSON)
                appendPart(name: "testSetupID", value: setupID)
                appendFilePart(name: "notebook", filename: "notebook.ipynb", data: studentNotebookData)
                body.writeString("--\(boundary)--\r\n")
                req.body = .init(buffer: body)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .ok, "browser-result POST should succeed, body: \(res.body.string)")
                if let json = try? JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: String] {
                    savedSubID = json["submissionID"] ?? ""
                }
            })

        XCTAssertFalse(savedSubID.isEmpty, "should have received a submissionID")

        // Find the saved .ipynb on disk and verify it contains the secret cell.
        let submission = try await APISubmission.find(savedSubID, on: app.db)
        let subPath    = try XCTUnwrap(submission?.zipPath)
        let savedData  = try Data(contentsOf: URL(fileURLWithPath: subPath))
        let savedJSON  = String(data: savedData, encoding: .utf8) ?? ""

        XCTAssertTrue(savedJSON.contains("tier=secret"),
                      "server must re-inject secret test cell into saved notebook")
        XCTAssertTrue(savedJSON.contains("x = 99"),
                      "student's solution cell must be present in saved notebook")
    }

    // MARK: - POST /api/v1/submissions/file — merge hidden test cells

    func testFileUploadMergesTestCells() async throws {
        let setupID = try await insertSetupWithNotebook(notebookJSON: mixedNotebookJSON)
        // submissions/file is instructor-tier (defensive endpoint, no student UI);
        // use an instructor cookie for this test.
        let cookie  = try await loginAsInstructor()

        // Simulate the student uploading a filtered notebook (no secret/release cells).
        let studentNotebookJSON = """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[
          {"cell_type":"code","source":["# TEST: pub tier=public\\nassert True"],"metadata":{},"outputs":[]},
          {"cell_type":"code","source":["y = 77"],"metadata":{},"outputs":[]}
        ]}
        """
        let studentNotebookData = studentNotebookJSON.data(using: .utf8)!

        var savedSubID = ""

        try await app.test(.POST, "/api/v1/submissions/file",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                var body = ByteBufferAllocator().buffer(capacity: 1024)
                let boundary = "TestBoundary67890"
                req.headers.contentType = HTTPMediaType(type: "multipart", subType: "form-data",
                                                         parameters: ["boundary": boundary])

                func appendPart(name: String, value: String) {
                    body.writeString("--\(boundary)\r\n")
                    body.writeString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
                    body.writeString(value)
                    body.writeString("\r\n")
                }
                func appendFilePart(name: String, filename: String, data: Data) {
                    body.writeString("--\(boundary)\r\n")
                    body.writeString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
                    body.writeString("Content-Type: application/json\r\n\r\n")
                    body.writeBytes(data)
                    body.writeString("\r\n")
                }

                appendPart(name: "testSetupID", value: setupID)
                appendPart(name: "filename",    value: "solution.ipynb")
                appendFilePart(name: "file", filename: "solution.ipynb", data: studentNotebookData)
                body.writeString("--\(boundary)--\r\n")
                req.body = .init(buffer: body)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .ok, "file upload should succeed, body: \(res.body.string)")
                if let json = try? JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: String] {
                    savedSubID = json["submissionID"] ?? ""
                }
            })

        XCTAssertFalse(savedSubID.isEmpty, "should have received a submissionID")

        let submission = try await APISubmission.find(savedSubID, on: app.db)
        let subPath    = try XCTUnwrap(submission?.zipPath)
        let savedData  = try Data(contentsOf: URL(fileURLWithPath: subPath))
        let savedJSON  = String(data: savedData, encoding: .utf8) ?? ""

        XCTAssertTrue(savedJSON.contains("tier=secret"),
                      "server must re-inject secret test cell into uploaded notebook")
        XCTAssertTrue(savedJSON.contains("y = 77"),
                      "student's solution cell must be present in saved notebook")
    }
}
