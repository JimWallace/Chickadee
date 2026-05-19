// Tests/APITests/NotebookDownloadTests.swift
//
// Integration tests for Phase 9 student download + offline upload.
//
//   GET  /api/v1/testsetups/:id/assignment         — role-aware filtering
//   GET  /api/v1/testsetups/:id/assignment/download — attachment + title filename
//   POST /api/v1/submissions/browser-result        — merges hidden test cells
//   POST /api/v1/submissions/file                  — merges hidden test cells

import Fluent
import Foundation
import Testing
import XCTVapor

@testable import chickadee_server

@Suite(.serialized) final class NotebookDownloadTests {

    // A notebook with 4 cells: public test, secret test, release test, solution.
    private let mixedNotebookJSON = """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[
          {"cell_type":"code","source":["# TEST: pub tier=public\\nassert True"],"metadata":{},"outputs":[]},
          {"cell_type":"code","source":["# TEST: sec tier=secret\\nassert True"],"metadata":{},"outputs":[]},
          {"cell_type":"code","source":["# TEST: rel tier=release\\nassert True"],"metadata":{},"outputs":[]},
          {"cell_type":"code","source":["x = 42"],"metadata":{},"outputs":[]}
        ]}
        """

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-dl")
    }

    // MARK: - Auth helpers

    private func loginAsInstructor() async throws -> String {
        return try await loginUser(username: "testinstructor", password: "testpassword", role: "instructor", on: app)
    }

    private func loginAsStudent() async throws -> String {
        return try await loginUser(username: "teststudent", password: "testpassword", role: "student", on: app)
    }

    /// Saves a notebook JSON directly as a flat .ipynb file and returns the setup ID.
    private func insertSetupWithNotebook(notebookJSON: String) async throws -> String {
        let setupID = "setup_test_\(UUID().uuidString.lowercased().prefix(6))"
        let notebookPath = app.testSetupsDirectory + "\(setupID).ipynb"
        let manifest = """
            {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}
            """
        // Write a dummy zip (the flat .ipynb takes priority in getAssignment).
        let dummyZipPath = app.testSetupsDirectory + "\(setupID).zip"
        try Data().write(to: URL(fileURLWithPath: dummyZipPath))
        try Data(notebookJSON.utf8).write(to: URL(fileURLWithPath: notebookPath))

        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let setup = APITestSetup(id: setupID, manifest: manifest, zipPath: dummyZipPath, courseID: courseID)
        setup.notebookPath = notebookPath
        try await setup.save(on: app.db)
        return setupID
    }

    // MARK: - GET /api/v1/testsetups/:id/assignment — role-aware filtering

    @Test func studentGetsFilteredNotebook() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSetupWithNotebook(notebookJSON: mixedNotebookJSON)
            let cookie = try await loginAsStudent()

            try await app.asyncTest(
                .GET, "/api/v1/testsetups/\(setupID)/assignment",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(body.contains("tier=secret") == false, "secret cell must be stripped for students")
                    #expect(body.contains("tier=release") == false, "release cell must be stripped for students")
                    #expect(body.contains("tier=public"), "public cell must be present for students")
                    #expect(body.contains("x = 42"), "solution cell must be present")
                })

        }
    }

    @Test func instructorGetsFullNotebook() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSetupWithNotebook(notebookJSON: mixedNotebookJSON)
            let cookie = try await loginAsInstructor()

            try await app.asyncTest(
                .GET, "/api/v1/testsetups/\(setupID)/assignment",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(body.contains("tier=secret"), "secret cell must be present for instructors")
                    #expect(body.contains("tier=release"), "release cell must be present for instructors")
                    #expect(body.contains("tier=public"), "public cell must be present for instructors")
                    #expect(body.contains("x = 42"), "solution cell must be present")
                })

        }
    }

    // MARK: - GET /api/v1/testsetups/:id/assignment/download

    @Test func downloadStripsHiddenCells() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSetupWithNotebook(notebookJSON: mixedNotebookJSON)
            let cookie = try await loginAsStudent()

            try await app.asyncTest(
                .GET, "/api/v1/testsetups/\(setupID)/assignment/download",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(body.contains("tier=secret") == false, "secret cell must not appear in download")
                    #expect(body.contains("tier=release") == false, "release cell must not appear in download")
                    #expect(body.contains("tier=public"), "public cell must appear in download")
                })

        }
    }

    @Test func downloadContentDispositionHeader() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSetupWithNotebook(notebookJSON: mixedNotebookJSON)
            let cookie = try await loginAsStudent()

            try await app.asyncTest(
                .GET, "/api/v1/testsetups/\(setupID)/assignment/download",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let cd = res.headers.first(name: .contentDisposition) ?? ""
                    #expect(cd.hasPrefix("attachment"), "response must have attachment disposition, got: \(cd)")
                })

        }
    }

    @Test func downloadFilenameUsesTitle() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSetupWithNotebook(notebookJSON: mixedNotebookJSON)
            let cookie = try await loginAsStudent()

            // Create an assignment record with a title.
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let a = APIAssignment(
                testSetupID: setupID, title: "Lab 1 Warmup", dueAt: nil, isOpen: true, courseID: courseID)
            try await a.save(on: app.db)

            try await app.asyncTest(
                .GET, "/api/v1/testsetups/\(setupID)/assignment/download",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let cd = res.headers.first(name: .contentDisposition) ?? ""
                    #expect(
                        cd.contains("Lab 1 Warmup.ipynb"),
                        "filename should be assignment title, got: \(cd)")
                })

        }
    }

    @Test func downloadFilenameFallsBackToSetupID() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSetupWithNotebook(notebookJSON: mixedNotebookJSON)
            let cookie = try await loginAsStudent()
            // No assignment record — filename falls back to setupID.

            try await app.asyncTest(
                .GET, "/api/v1/testsetups/\(setupID)/assignment/download",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let cd = res.headers.first(name: .contentDisposition) ?? ""
                    #expect(
                        cd.contains("\(setupID).ipynb"),
                        "filename should fall back to setupID, got: \(cd)")
                })

        }
    }

    @Test func unauthenticatedCannotDownload() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSetupWithNotebook(notebookJSON: mixedNotebookJSON)

            try await app.asyncTest(
                .GET, "/api/v1/testsetups/\(setupID)/assignment/download",
                afterResponse: { res in
                    // Should redirect to login or return 401.
                    #expect(
                        res.status == .unauthorized || res.status == .seeOther,
                        "unauthenticated download should be rejected, got \(res.status)")
                })

        }
    }

    @Test func studentCannotUploadTestSetup() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent()
            // Obtain a valid CSRF token so the middleware passes and the role check fires.
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)

            // POST to /api/v1/testsetups as a student should return 403 (instructor-only).
            let boundary = "RoleCheck"
            var body = ByteBufferAllocator().buffer(capacity: 256)
            body.writeString("--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"_csrf\"\r\n\r\n")
            body.writeString(csrf)
            body.writeString("\r\n--\(boundary)--\r\n")

            try await app.asyncTest(
                .POST, "/api/v1/testsetups",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart", subType: "form-data",
                        parameters: ["boundary": boundary])
                    req.body = .init(buffer: body)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })

        }
    }

    // MARK: - POST /api/v1/submissions/browser-result — merge hidden test cells

    @Test func browserSubmitMergesTestCells() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSetupWithNotebook(notebookJSON: mixedNotebookJSON)
            let cookie = try await loginAsStudent()
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)

            // Simulate the student's notebook: only the public cell + solution cell
            // (as if they downloaded the filtered version).
            let studentNotebookJSON = """
                {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[
                  {"cell_type":"code","source":["# TEST: pub tier=public\\nassert True"],"metadata":{},"outputs":[]},
                  {"cell_type":"code","source":["x = 99"],"metadata":{},"outputs":[]}
                ]}
                """
            let studentNotebookData = Data(studentNotebookJSON.utf8)

            // Build a minimal valid TestOutcomeCollection JSON.
            let collectionJSON = """
                {"submissionID":"","testSetupID":"\(setupID)","attemptNumber":1,
                 "buildStatus":"passed","compilerOutput":null,"outcomes":[],
                 "totalTests":0,"passCount":0,"failCount":0,"errorCount":0,"timeoutCount":0,
                 "executionTimeMs":0,"runnerVersion":"browser-pyodide/1.0",
                 "timestamp":"2026-01-01T00:00:00Z"}
                """

            var savedSubID = ""

            try await app.asyncTest(
                .POST, "/api/v1/submissions/browser-result",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    // Build multipart body.
                    var body = ByteBufferAllocator().buffer(capacity: 1024)
                    let boundary = "TestBoundary12345"
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart", subType: "form-data",
                        parameters: ["boundary": boundary])

                    func appendPart(name: String, value: String) {
                        body.writeString("--\(boundary)\r\n")
                        body.writeString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
                        body.writeString(value)
                        body.writeString("\r\n")
                    }
                    func appendFilePart(name: String, filename: String, data: Data) {
                        body.writeString("--\(boundary)\r\n")
                        body.writeString(
                            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
                        body.writeString("Content-Type: application/json\r\n\r\n")
                        body.writeBytes(data)
                        body.writeString("\r\n")
                    }

                    appendPart(name: "_csrf", value: csrf)
                    appendPart(name: "collection", value: collectionJSON)
                    appendPart(name: "testSetupID", value: setupID)
                    appendFilePart(name: "notebook", filename: "notebook.ipynb", data: studentNotebookData)
                    body.writeString("--\(boundary)--\r\n")
                    req.body = .init(buffer: body)
                },
                afterResponse: { res in
                    #expect(res.status == .ok, "browser-result POST should succeed, body: \(res.body.string)")
                    if let json = try? JSONSerialization.jsonObject(with: Data(res.body.readableBytesView))
                        as? [String: String]
                    {
                        savedSubID = json["submissionID"] ?? ""
                    }
                })

            #expect(savedSubID.isEmpty == false, "should have received a submissionID")

            // Find the saved .ipynb on disk and verify it contains the secret cell.
            let submission = try await APISubmission.find(savedSubID, on: app.db)
            let subPath = try #require(submission?.zipPath)
            let savedData = try Data(contentsOf: URL(fileURLWithPath: subPath))
            let savedJSON = String(data: savedData, encoding: .utf8) ?? ""

            #expect(
                savedJSON.contains("tier=secret"),
                "server must re-inject secret test cell into saved notebook")
            #expect(
                savedJSON.contains("x = 99"),
                "student's solution cell must be present in saved notebook")

        }
    }

    // MARK: - POST /api/v1/submissions/browser-result — single submission, no worker re-queue

    @Test func browserSubmitCreatesSingleBrowserCompleteSubmission() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSetupWithNotebook(notebookJSON: mixedNotebookJSON)
            let cookie = try await loginAsStudent()
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)

            let notebookData = Data(mixedNotebookJSON.utf8)
            let collectionJSON = """
                {"submissionID":"","testSetupID":"\(setupID)","attemptNumber":1,
                 "buildStatus":"passed","compilerOutput":null,"outcomes":[],
                 "totalTests":0,"passCount":0,"failCount":0,"errorCount":0,"timeoutCount":0,
                 "executionTimeMs":0,"runnerVersion":"browser-wasm-runner/1.0",
                 "timestamp":"2026-01-01T00:00:00Z"}
                """

            var savedSubID = ""

            try await app.asyncTest(
                .POST, "/api/v1/submissions/browser-result",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    var body = ByteBufferAllocator().buffer(capacity: 1024)
                    let boundary = "Boundary9876"
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart", subType: "form-data",
                        parameters: ["boundary": boundary])
                    func part(_ name: String, _ value: String) {
                        body.writeString("--\(boundary)\r\n")
                        body.writeString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
                        body.writeString(value + "\r\n")
                    }
                    func filePart(_ name: String, _ filename: String, _ data: Data) {
                        body.writeString("--\(boundary)\r\n")
                        body.writeString(
                            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
                        body.writeString("Content-Type: application/json\r\n\r\n")
                        body.writeBytes(data)
                        body.writeString("\r\n")
                    }
                    part("_csrf", csrf)
                    part("collection", collectionJSON)
                    part("testSetupID", setupID)
                    filePart("notebook", "notebook.ipynb", notebookData)
                    body.writeString("--\(boundary)--\r\n")
                    req.body = .init(buffer: body)
                },
                afterResponse: { res in
                    #expect(res.status == .ok, "browser-result POST should succeed")
                    if let json = try? JSONSerialization.jsonObject(with: Data(res.body.readableBytesView))
                        as? [String: String]
                    {
                        savedSubID = json["submissionID"] ?? ""
                        // Verify no workerSubmissionID is returned — we no longer re-queue.
                        #expect(
                            json["workerSubmissionID"] == nil, "browser-result must not return a workerSubmissionID")
                    }
                })

            #expect(savedSubID.isEmpty == false)

            // Exactly ONE submission must exist in the DB (complete), no pending re-run.
            let allSubs = try await APISubmission.query(on: app.db).all()
            #expect(allSubs.count == 1, "Only one submission record should be created")
            #expect(allSubs[0].status == "complete", "The single submission should have status 'complete'")
            #expect(
                allSubs.contains(where: { $0.status == "pending" }) == false,
                "No pending worker re-run submission should exist")

        }
    }

    // MARK: - POST /api/v1/submissions/file — merge hidden test cells

    @Test func fileUploadMergesTestCells() async throws {
        try await withApp(app) { _ in
            let setupID = try await insertSetupWithNotebook(notebookJSON: mixedNotebookJSON)
            // submissions/file is instructor-tier (defensive endpoint, no student UI);
            // use an instructor cookie for this test.
            let cookie = try await loginAsInstructor()
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)

            // Simulate the student uploading a filtered notebook (no secret/release cells).
            let studentNotebookJSON = """
                {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[
                  {"cell_type":"code","source":["# TEST: pub tier=public\\nassert True"],"metadata":{},"outputs":[]},
                  {"cell_type":"code","source":["y = 77"],"metadata":{},"outputs":[]}
                ]}
                """
            let studentNotebookData = Data(studentNotebookJSON.utf8)

            var savedSubID = ""

            try await app.asyncTest(
                .POST, "/api/v1/submissions/file",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    var body = ByteBufferAllocator().buffer(capacity: 1024)
                    let boundary = "TestBoundary67890"
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart", subType: "form-data",
                        parameters: ["boundary": boundary])

                    func appendPart(name: String, value: String) {
                        body.writeString("--\(boundary)\r\n")
                        body.writeString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
                        body.writeString(value)
                        body.writeString("\r\n")
                    }
                    func appendFilePart(name: String, filename: String, data: Data) {
                        body.writeString("--\(boundary)\r\n")
                        body.writeString(
                            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
                        body.writeString("Content-Type: application/json\r\n\r\n")
                        body.writeBytes(data)
                        body.writeString("\r\n")
                    }

                    appendPart(name: "_csrf", value: csrf)
                    appendPart(name: "testSetupID", value: setupID)
                    appendPart(name: "filename", value: "solution.ipynb")
                    appendFilePart(name: "file", filename: "solution.ipynb", data: studentNotebookData)
                    body.writeString("--\(boundary)--\r\n")
                    req.body = .init(buffer: body)
                },
                afterResponse: { res in
                    #expect(res.status == .ok, "file upload should succeed, body: \(res.body.string)")
                    if let json = try? JSONSerialization.jsonObject(with: Data(res.body.readableBytesView))
                        as? [String: String]
                    {
                        savedSubID = json["submissionID"] ?? ""
                    }
                })

            #expect(savedSubID.isEmpty == false, "should have received a submissionID")

            let submission = try await APISubmission.find(savedSubID, on: app.db)
            let subPath = try #require(submission?.zipPath)
            let savedData = try Data(contentsOf: URL(fileURLWithPath: subPath))
            let savedJSON = String(data: savedData, encoding: .utf8) ?? ""

            #expect(
                savedJSON.contains("tier=secret"),
                "server must re-inject secret test cell into uploaded notebook")
            #expect(
                savedJSON.contains("y = 77"),
                "student's solution cell must be present in saved notebook")

        }
    }
}
