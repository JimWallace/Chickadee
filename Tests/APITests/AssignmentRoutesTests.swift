// Tests/APITests/AssignmentRoutesTests.swift
//
// Integration tests for Phase 7 instructor assignment management routes.
//
//   GET  /instructor
//   POST /instructor                       (publish → draft)
//   GET  /instructor/:id/validate
//   POST /instructor/:id/open
//   POST /instructor/:id/close
//   POST /instructor/:id/delete

import XCTest
import XCTVapor
@testable import chickadee_server
import FluentSQLiteDriver
import Foundation
import Core

final class AssignmentRoutesTests: XCTestCase {

    private var app: Application!
    private var tmpDir: String!

    override func setUp() async throws {
        app = try await Application.make(.testing)

        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-art-\(UUID().uuidString)/")
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
        app.migrations.add(AddCourseEnrollmentMode())
        try await app.autoMigrate()

        configureLeaf(app)
        try routes(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    // MARK: - Auth helpers

    private func loginAsInstructor() async throws -> String {
        return try await loginUser(username: "testinstructor", password: "testpassword", role: "instructor", on: app)
    }

    private func loginAsStudent() async throws -> String {
        return try await loginUser(username: "teststudent", password: "testpassword", role: "student", on: app)
    }

    // MARK: - Setup helper

    private func makeTestCourseID() async throws -> UUID {
        if let existing = try await APICourse.query(on: app.db).filter(\.$code == "TEST101").first() {
            return try existing.requireID()
        }
        let course = APICourse(code: "TEST101", name: "Test Course", enrollmentMode: .auto)
        try await course.save(on: app.db)
        return try course.requireID()
    }

    @discardableResult
    private func insertSetup(id: String) async throws -> APITestSetup {
        let manifest = """
        {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10,"makefile":null}
        """
        let courseID = try await makeTestCourseID()
        let setup = APITestSetup(id: id, manifest: manifest, zipPath: tmpDir + "testsetups/\(id).zip", courseID: courseID)
        try await setup.save(on: app.db)
        return setup
    }

    @discardableResult
    private func insertAssignment(testSetupID: String, title: String, isOpen: Bool) async throws -> APIAssignment {
        let courseID = try await makeTestCourseID()
        let a = APIAssignment(testSetupID: testSetupID, title: title, dueAt: nil, isOpen: isOpen, courseID: courseID)
        try await a.save(on: app.db)
        return a
    }

    @discardableResult
    private func insertStudent(username: String = "student_retest") async throws -> APIUser {
        let hash = try Bcrypt.hash("testpassword")
        let student = APIUser(username: username, passwordHash: hash, role: "student")
        try await student.save(on: app.db)
        return student
    }

    private func multipartAssignmentBody(
        boundary: String,
        csrf: String,
        assignmentName: String,
        assignmentNotebook: String,
        solutionNotebook: String,
        suiteFiles: [(filename: String, contentType: String, content: String)] = [],
        suiteConfig: String? = nil
    ) -> ByteBuffer {
        var body = ByteBufferAllocator().buffer(capacity: 4096)

        func appendField(_ name: String, _ value: String) {
            body.writeString("--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.writeString(value)
            body.writeString("\r\n")
        }

        func appendFile(_ name: String, filename: String, contentType: String = "application/json", data: Data) {
            body.writeString("--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
            body.writeString("Content-Type: \(contentType)\r\n\r\n")
            body.writeBytes(data)
            body.writeString("\r\n")
        }

        appendField("_csrf", csrf)
        appendField("assignmentName", assignmentName)
        appendFile(
            "assignmentNotebookFile",
            filename: "assignment.ipynb",
            data: Data(assignmentNotebook.utf8)
        )
        appendFile(
            "solutionNotebookFile",
            filename: "solution.ipynb",
            data: Data(solutionNotebook.utf8)
        )
        for suiteFile in suiteFiles {
            appendFile(
                "suiteFiles",
                filename: suiteFile.filename,
                contentType: suiteFile.contentType,
                data: Data(suiteFile.content.utf8)
            )
        }
        if let suiteConfig {
            appendField("suiteConfig", suiteConfig)
        }
        body.writeString("--\(boundary)--\r\n")
        return body
    }

    private func multipartEditBody(
        boundary: String,
        csrf: String,
        assignmentName: String,
        assignmentNotebook: String,
        solutionNotebook: String,
        suiteConfig: String
    ) -> ByteBuffer {
        var body = ByteBufferAllocator().buffer(capacity: 4096)

        func appendField(_ name: String, _ value: String) {
            body.writeString("--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.writeString(value)
            body.writeString("\r\n")
        }

        func appendFile(_ name: String, filename: String, contentType: String = "application/json", data: Data) {
            body.writeString("--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
            body.writeString("Content-Type: \(contentType)\r\n\r\n")
            body.writeBytes(data)
            body.writeString("\r\n")
        }

        appendField("_csrf", csrf)
        appendField("assignmentName", assignmentName)
        appendFile(
            "assignmentNotebookFile",
            filename: "assignment.ipynb",
            data: Data(assignmentNotebook.utf8)
        )
        appendFile(
            "solutionNotebookFile",
            filename: "solution.ipynb",
            data: Data(solutionNotebook.utf8)
        )
        appendField("suiteConfig", suiteConfig)
        body.writeString("--\(boundary)--\r\n")
        return body
    }

    private func makeZip(at path: String, entries: [(String, String)]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("assignment-routes-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for (name, contents) in entries {
            let fileURL = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.data(using: .utf8)?.write(to: fileURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = root
        process.arguments = ["-q", "-r", path, "."]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - GET /instructor

    func testStudentCannotAccessAssignments() async throws {
        let cookie = try await loginAsStudent()
        try await app.asyncTest(.GET, "/instructor", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .forbidden)
        })
    }

    func testInstructorCanAccessAssignments() async throws {
        let cookie = try await loginAsInstructor()
        try await app.asyncTest(.GET, "/instructor", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            // 500 expected because Leaf is not configured in tests — but middleware passed (not 401/403).
            XCTAssertNotEqual(res.status, .unauthorized)
            XCTAssertNotEqual(res.status, .forbidden)
        })
    }

    // MARK: - POST /instructor (publish → creates draft)

    func testPublishCreatesDraftAssignment() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
        try await insertSetup(id: "setup_pub1")

        try await app.asyncTest(.POST, "/instructor", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(
                ["testSetupID": "setup_pub1", "title": "Lab 1", "_csrf": csrf],
                as: .urlEncodedForm
            )
        }, afterResponse: { res in
            // Redirects to /instructor/:id/validate
            XCTAssertEqual(res.status, .seeOther)
            let location = res.headers.first(name: .location) ?? ""
            XCTAssertTrue(location.contains("/instructor/") && location.contains("/validate"),
                          "Expected redirect to /instructor/:id/validate, got \(location)")
        })

        // Assignment should be in DB as draft (isOpen: false)
        let assignment = try await APIAssignment.query(on: app.db)
            .filter(\.$testSetupID == "setup_pub1")
            .first()
        XCTAssertNotNil(assignment)
        XCTAssertEqual(assignment?.title, "Lab 1")
        XCTAssertEqual(assignment?.isOpen, false)
    }

    func testPublishUnknownSetupReturnsBadRequest() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/instructor", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(
                ["testSetupID": "does_not_exist", "title": "Oops", "_csrf": csrf],
                as: .urlEncodedForm
            )
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    func testPublishDuplicateSetupRedirects() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
        try await insertSetup(id: "setup_dup")
        try await insertAssignment(testSetupID: "setup_dup", title: "Already Published", isOpen: false)

        try await app.asyncTest(.POST, "/instructor", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(
                ["testSetupID": "setup_dup", "title": "Duplicate", "_csrf": csrf],
                as: .urlEncodedForm
            )
        }, afterResponse: { res in
            // Should redirect to /instructor without creating a second record
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/instructor")
        })

        let count = try await APIAssignment.query(on: app.db)
            .filter(\.$testSetupID == "setup_dup")
            .count()
        XCTAssertEqual(count, 1)
    }

    func testSaveNewAssignmentAllowsMissingTestSuites() async throws {
        _ = try await makeTestCourseID()
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)
        let boundary = "Boundary-New-NoSuites"
        let notebook = #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#

        try await app.asyncTest(.POST, "/instructor/new/save", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.contentType = HTTPMediaType(
                type: "multipart",
                subType: "form-data",
                parameters: ["boundary": boundary]
            )
            req.body = .init(buffer: self.multipartAssignmentBody(
                boundary: boundary,
                csrf: csrf,
                assignmentName: "No Tests Yet",
                assignmentNotebook: notebook,
                solutionNotebook: notebook
            ))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/instructor")
        })

        let assignment = try await APIAssignment.query(on: app.db)
            .filter(\.$title == "No Tests Yet")
            .first()
        XCTAssertNotNil(assignment)
        XCTAssertNil(assignment?.validationStatus)
        XCTAssertNil(assignment?.validationSubmissionID)

        let setupID = try XCTUnwrap(assignment?.testSetupID)
        let setup = try await APITestSetup.find(setupID, on: app.db)
        XCTAssertNotNil(setup)
        let setupManifest = try XCTUnwrap(setup?.manifest.data(using: .utf8))
        let props = try JSONDecoder().decode(TestProperties.self, from: setupManifest)
        XCTAssertTrue(props.testSuites.isEmpty)
    }

    func testSaveNewAssignmentPreservesMultipleUploadedSuiteFiles() async throws {
        _ = try await makeTestCourseID()
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)
        let boundary = "Boundary-New-MultiSuites"
        let notebook = #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#
        let suiteConfig = """
        [
          {"index":0,"tier":"public","order":1,"points":1},
          {"index":1,"tier":"public","order":2,"points":1},
          {"index":2,"tier":"support","order":3,"points":1}
        ]
        """

        try await app.asyncTest(.POST, "/instructor/new/save", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.contentType = HTTPMediaType(
                type: "multipart",
                subType: "form-data",
                parameters: ["boundary": boundary]
            )
            req.body = .init(buffer: self.multipartAssignmentBody(
                boundary: boundary,
                csrf: csrf,
                assignmentName: "Practice Lab",
                assignmentNotebook: notebook,
                solutionNotebook: notebook,
                suiteFiles: [
                    ("test_q1.py", "text/plain", "print('q1')"),
                    ("test_q2.py", "text/plain", "print('q2')"),
                    ("test.properties.json", "application/json", #"{"gradingMode":"browser"}"#)
                ],
                suiteConfig: suiteConfig
            ))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/instructor")
        })

        let assignment = try await APIAssignment.query(on: app.db)
            .filter(\.$title == "Practice Lab")
            .first()
        let setupID = try XCTUnwrap(assignment?.testSetupID)
        let setup = try await APITestSetup.find(setupID, on: app.db)
        XCTAssertNotNil(setup)

        let props = try JSONDecoder().decode(
            TestProperties.self,
            from: try XCTUnwrap(setup?.manifest.data(using: .utf8))
        )
        XCTAssertEqual(props.testSuites.map(\.script), ["test_q1.py", "test_q2.py"])

        let zipEntries = Set(listZipEntries(zipPath: try XCTUnwrap(setup?.zipPath)))
        XCTAssertTrue(zipEntries.contains("test_q1.py"))
        XCTAssertTrue(zipEntries.contains("test_q2.py"))
        XCTAssertTrue(zipEntries.contains("test.properties.json"))
    }

    func testSaveEditedAssignmentPersistsDisplayNameForExistingSuiteFile() async throws {
        let courseID = try await makeTestCourseID()
        let cookie = try await loginAsInstructor()
        let setupID = "setup_edit_display"
        let zipPath = tmpDir + "testsetups/\(setupID).zip"
        try makeZip(at: zipPath, entries: [("test_q1.py", "print('q1')")])
        let manifest = """
        {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[{"tier":"public","script":"test_q1.py"}],"timeLimitSeconds":10,"makefile":null}
        """
        let setup = APITestSetup(id: setupID, manifest: manifest, zipPath: zipPath, notebookPath: tmpDir + "testsetups/notebooks/\(setupID)/assignment.ipynb", courseID: courseID)
        try await setup.save(on: app.db)
        let assignment = APIAssignment(publicID: "ABC123", testSetupID: setupID, title: "Practice Lab", dueAt: nil, isOpen: false, courseID: courseID)
        try await assignment.save(on: app.db)

        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/ABC123/edit", cookie: cookie, on: app)
        let boundary = "Boundary-Edit-DisplayName"
        let notebook = #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#
        let suiteConfig = """
        [
          {"source":"existing","name":"test_q1.py","tier":"public","order":1,"points":1,"displayName":"BMI check"}
        ]
        """

        try await app.asyncTest(.POST, "/instructor/ABC123/edit/save", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.contentType = HTTPMediaType(
                type: "multipart",
                subType: "form-data",
                parameters: ["boundary": boundary]
            )
            req.body = .init(buffer: self.multipartEditBody(
                boundary: boundary,
                csrf: csrf,
                assignmentName: "Practice Lab",
                assignmentNotebook: notebook,
                solutionNotebook: notebook,
                suiteConfig: suiteConfig
            ))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
        })

        let savedSetup = try await APITestSetup.find(setupID, on: app.db)
        let props = try JSONDecoder().decode(
            TestProperties.self,
            from: try XCTUnwrap(savedSetup?.manifest.data(using: .utf8))
        )
        XCTAssertEqual(props.testSuites.count, 1)
        XCTAssertEqual(props.testSuites[0].name, "BMI check")
    }

    func testEditPageSyncsSuiteConfigOnSubmit() async throws {
        let courseID = try await makeTestCourseID()
        let cookie = try await loginAsInstructor()
        let setupID = "setup_edit_submit_sync"
        let zipPath = tmpDir + "testsetups/\(setupID).zip"
        try makeZip(at: zipPath, entries: [("test_q1.py", "print('q1')")])
        let manifest = """
        {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[{"tier":"public","script":"test_q1.py"}],"timeLimitSeconds":10,"makefile":null}
        """
        let setup = APITestSetup(id: setupID, manifest: manifest, zipPath: zipPath, notebookPath: tmpDir + "testsetups/notebooks/\(setupID)/assignment.ipynb", courseID: courseID)
        try await setup.save(on: app.db)
        let assignment = APIAssignment(publicID: "DEF456", testSetupID: setupID, title: "Practice Lab", dueAt: nil, isOpen: false, courseID: courseID)
        try await assignment.save(on: app.db)

        try await app.asyncTest(.GET, "/instructor/DEF456/edit", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            XCTAssertTrue(html.contains("form.addEventListener('submit'"))
            XCTAssertTrue(html.contains("syncConfig();"))
        })
    }

    func testNewAssignmentPageOmitsLegacyTestColumn() async throws {
        _ = try await makeTestCourseID()
        let cookie = try await loginAsInstructor()

        try await app.asyncTest(.GET, "/instructor/new", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let body = res.body.string
            XCTAssertFalse(body.contains("<th>Test?</th>"))
            XCTAssertTrue(body.contains("<th>Tier</th>"))
            XCTAssertTrue(body.contains("support"))
        })
    }

    // MARK: - POST /instructor/:id/open

    func testOpenAssignmentSetsIsOpenTrue() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
        try await insertSetup(id: "setup_open")
        let a = try await insertAssignment(testSetupID: "setup_open", title: "Draft", isOpen: false)
        let id = a.publicID

        try await app.asyncTest(.POST, "/instructor/\(id)/open", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/instructor")
        })

        let updated = try await APIAssignment.find(a.id, on: app.db)
        XCTAssertEqual(updated?.isOpen, true)
    }

    // MARK: - POST /instructor/:id/close

    func testCloseAssignmentSetsIsOpenFalse() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
        try await insertSetup(id: "setup_close")
        let a = try await insertAssignment(testSetupID: "setup_close", title: "Open", isOpen: true)
        let id = a.publicID

        try await app.asyncTest(.POST, "/instructor/\(id)/close", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
        })

        let updated = try await APIAssignment.find(a.id, on: app.db)
        XCTAssertEqual(updated?.isOpen, false)
    }

    // MARK: - POST /instructor/:id/delete

    func testDeleteAssignmentRemovesRecord() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
        try await insertSetup(id: "setup_del")
        let a = try await insertAssignment(testSetupID: "setup_del", title: "To Remove", isOpen: false)
        let id = a.publicID

        try await app.asyncTest(.POST, "/instructor/\(id)/delete", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
        })

        let gone = try await APIAssignment.find(a.id, on: app.db)
        XCTAssertNil(gone)
    }

    func testDeleteNonexistentAssignmentReturnsNotFound() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
        let fakeID = "zzzzzz"

        try await app.asyncTest(.POST, "/instructor/\(fakeID)/delete", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    // MARK: - POST /instructor/:id/open — nonexistent

    func testOpenNonexistentAssignmentReturnsNotFound() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
        let fakeID = "zzzzzz"

        try await app.asyncTest(.POST, "/instructor/\(fakeID)/open", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    // MARK: - POST /instructor/:assignmentID/submissions/:submissionID/retest

    func testRetestSubmissionRequeuesCompletedSubmission() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
        try await insertSetup(id: "setup_retest")
        let assignment = try await insertAssignment(testSetupID: "setup_retest", title: "Lab Retest", isOpen: true)
        let assignmentID = assignment.publicID
        let student = try await insertStudent()

        let submission = APISubmission(
            id: "sub_retest_1",
            testSetupID: "setup_retest",
            zipPath: tmpDir + "submissions/sub_retest_1.zip",
            attemptNumber: 1,
            status: "complete",
            userID: student.id
        )
        submission.workerID = "worker-a"
        submission.assignedAt = Date()
        try await submission.save(on: app.db)

        try await app.asyncTest(.POST, "/instructor/\(assignmentID)/submissions/sub_retest_1/retest", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(
                ["returnTo": "/instructor/\(assignmentID)/submissions", "_csrf": csrf],
                as: .urlEncodedForm
            )
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/instructor/\(assignmentID)/submissions")
        })

        let updated = try await APISubmission.find("sub_retest_1", on: app.db)
        XCTAssertEqual(updated?.status, "pending")
        XCTAssertNil(updated?.workerID)
        XCTAssertNil(updated?.assignedAt)
    }

    func testRetestSubmissionRequiresMatchingAssignmentSetup() async throws {
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
        try await insertSetup(id: "setup_a")
        try await insertSetup(id: "setup_b")
        let assignment = try await insertAssignment(testSetupID: "setup_a", title: "Lab A", isOpen: true)
        let assignmentID = assignment.publicID
        let student = try await insertStudent(username: "student_other_setup")

        let submission = APISubmission(
            id: "sub_retest_mismatch",
            testSetupID: "setup_b",
            zipPath: tmpDir + "submissions/sub_retest_mismatch.zip",
            attemptNumber: 1,
            status: "complete",
            userID: student.id
        )
        try await submission.save(on: app.db)

        try await app.asyncTest(.POST, "/instructor/\(assignmentID)/submissions/sub_retest_mismatch/retest", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
    }
}
