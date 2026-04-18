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
import Fluent
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

        try await configureTestDatabase(app)

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
    private func insertAssignment(
        testSetupID: String,
        title: String,
        isOpen: Bool,
        dueAt: Date? = nil,
        deadlineOverrideActive: Bool = false
    ) async throws -> APIAssignment {
        let courseID = try await makeTestCourseID()
        let a = APIAssignment(
            testSetupID: testSetupID,
            title: title,
            dueAt: dueAt,
            isOpen: isOpen,
            deadlineOverrideActive: deadlineOverrideActive,
            courseID: courseID
        )
        try await a.save(on: app.db)
        return a
    }

    @discardableResult
    private func insertStudent(
        username: String = "student_retest",
        displayName: String? = nil,
        preferredName: String? = nil
    ) async throws -> APIUser {
        let hash = try Bcrypt.hash("testpassword")
        let student = APIUser(
            username: username,
            passwordHash: hash,
            role: "student",
            preferredName: preferredName,
            displayName: displayName
        )
        try await student.save(on: app.db)
        return student
    }

    private func enrollStudentInTestCourse(_ student: APIUser) async throws {
        let courseID = try await makeTestCourseID()
        let enrollment = APICourseEnrollment(
            userID: try student.requireID(),
            courseID: courseID
        )
        try await enrollment.save(on: app.db)
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

    private func multipartBody(
        boundary: String,
        fields: [(String, String)],
        files: [(name: String, filename: String, contentType: String, data: Data)] = []
    ) -> ByteBuffer {
        var body = ByteBufferAllocator().buffer(capacity: 4096)

        func appendField(_ name: String, _ value: String) {
            body.writeString("--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.writeString(value)
            body.writeString("\r\n")
        }

        func appendFile(_ file: (name: String, filename: String, contentType: String, data: Data)) {
            body.writeString("--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\"\r\n")
            body.writeString("Content-Type: \(file.contentType)\r\n\r\n")
            body.writeBytes(file.data)
            body.writeString("\r\n")
        }

        fields.forEach(appendField)
        files.forEach(appendFile)
        body.writeString("--\(boundary)--\r\n")
        return body
    }

    func testCloseExpiredAssignmentsClosesOnlyEligibleAssignments() async throws {
        _ = try await insertSetup(id: "setup_deadline_close")
        let overdue = try await insertAssignment(
            testSetupID: "setup_deadline_close",
            title: "Overdue",
            isOpen: true,
            dueAt: Date().addingTimeInterval(-60)
        )

        _ = try await insertSetup(id: "setup_deadline_open")
        let noDeadline = try await insertAssignment(
            testSetupID: "setup_deadline_open",
            title: "No Deadline",
            isOpen: true
        )

        _ = try await insertSetup(id: "setup_deadline_override")
        let overridden = try await insertAssignment(
            testSetupID: "setup_deadline_override",
            title: "Override",
            isOpen: true,
            dueAt: Date().addingTimeInterval(-60),
            deadlineOverrideActive: true
        )

        let closedCount = try await closeExpiredAssignments(on: app.db, logger: app.logger)
        XCTAssertEqual(closedCount, 1)

        let overdueReloadedOptional = try await APIAssignment.find(overdue.id, on: app.db)
        XCTAssertNotNil(overdueReloadedOptional)
        let overdueReloaded = overdueReloadedOptional!
        XCTAssertFalse(overdueReloaded.isOpen)

        let noDeadlineReloadedOptional = try await APIAssignment.find(noDeadline.id, on: app.db)
        XCTAssertNotNil(noDeadlineReloadedOptional)
        let noDeadlineReloaded = noDeadlineReloadedOptional!
        XCTAssertTrue(noDeadlineReloaded.isOpen)

        let overriddenReloadedOptional = try await APIAssignment.find(overridden.id, on: app.db)
        XCTAssertNotNil(overriddenReloadedOptional)
        let overriddenReloaded = overriddenReloadedOptional!
        XCTAssertTrue(overriddenReloaded.isOpen)
    }

    func testInstructorCanReopenPastDueAssignmentWithOverride() async throws {
        _ = try await insertSetup(id: "setup_reopen_deadline")
        let assignment = try await insertAssignment(
            testSetupID: "setup_reopen_deadline",
            title: "Past Due",
            isOpen: false,
            dueAt: Date().addingTimeInterval(-60)
        )
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/instructor/\(assignment.publicID)/open", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.add(name: "x-csrf-token", value: csrf)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
        })

        let reopenedOptional = try await APIAssignment.find(assignment.id, on: app.db)
        XCTAssertNotNil(reopenedOptional)
        let reopened = reopenedOptional!
        XCTAssertTrue(reopened.isOpen)
        XCTAssertEqual(reopened.deadlineOverrideActive, true)

        _ = try await closeExpiredAssignments(on: app.db, logger: app.logger)
        let stillOpenOptional = try await APIAssignment.find(assignment.id, on: app.db)
        XCTAssertNotNil(stillOpenOptional)
        let stillOpen = stillOpenOptional!
        XCTAssertTrue(stillOpen.isOpen)
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

    func testAssignmentsPageUsesDedicatedEnrollCSVPageLink() async throws {
        _ = try await makeTestCourseID()
        let cookie = try await loginAsInstructor()

        try await app.asyncTest(.GET, "/instructor", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            XCTAssertTrue(html.contains("href=\"/instructor/enroll-csv\""))
            XCTAssertFalse(html.contains("id=\"enroll-csv-file\""))
        })
    }

    func testAssignmentsPageDefaultsEnrolledStudentsToMostRecentLastLoginFirst() async throws {
        _ = try await makeTestCourseID()
        let cookie = try await loginAsInstructor()
        let now = Date()

        let never = try await insertStudent(username: "never_login_student", displayName: "Never Login")
        try await enrollStudentInTestCourse(never)

        let older = try await insertStudent(username: "older_login_student", displayName: "Older Login")
        older.lastLoginAt = now.addingTimeInterval(-3600)
        try await older.save(on: app.db)
        try await enrollStudentInTestCourse(older)

        let recent = try await insertStudent(username: "recent_login_student", displayName: "Recent Login")
        recent.lastLoginAt = now
        try await recent.save(on: app.db)
        try await enrollStudentInTestCourse(recent)

        try await app.asyncTest(.GET, "/instructor", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            XCTAssertTrue(html.contains("id=\"enrolled-students-table\""))
            XCTAssertTrue(html.contains("var sortCol = 3;"))
            XCTAssertTrue(html.contains("var sortAsc = false;"))
            let recentIndex = try XCTUnwrap(html.range(of: "recent_login_student")?.lowerBound)
            let olderIndex = try XCTUnwrap(html.range(of: "older_login_student")?.lowerBound)
            let neverIndex = try XCTUnwrap(html.range(of: "never_login_student")?.lowerBound)
            XCTAssertLessThan(recentIndex, olderIndex)
            XCTAssertLessThan(olderIndex, neverIndex)
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
        app.migrations.add(CreateRunnerProfiles())
        app.migrations.add(CreateAssignmentRequirements())
        try await app.autoMigrate()
        let now = Date()
        let runnerProfile = RunnerProfile()
        runnerProfile.runnerID = "runner-multi-suite"
        runnerProfile.displayName = "Runner Multi Suite"
        runnerProfile.platform = "linux"
        runnerProfile.architecture = "x86_64"
        runnerProfile.languageVersionsJSON = "[]"
        runnerProfile.capabilitiesJSON = "[]"
        runnerProfile.profileHash = nil
        runnerProfile.lastRegisteredAt = now
        runnerProfile.lastSeenAt = now
        runnerProfile.isActive = true
        try await runnerProfile.save(on: app.db)
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

    func testSaveEditedAssignmentShowsUpdatedDisplayNameOnReopen() async throws {
        let courseID = try await makeTestCourseID()
        let cookie = try await loginAsInstructor()
        let setupID = "setup_edit_display_reload"
        let zipPath = tmpDir + "testsetups/\(setupID).zip"
        try makeZip(at: zipPath, entries: [("test_q1.py", "print('q1')")])
        let manifest = """
        {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[{"tier":"public","script":"test_q1.py"}],"timeLimitSeconds":10,"makefile":null}
        """
        let setup = APITestSetup(id: setupID, manifest: manifest, zipPath: zipPath, notebookPath: tmpDir + "testsetups/notebooks/\(setupID)/assignment.ipynb", courseID: courseID)
        try await setup.save(on: app.db)
        let assignment = APIAssignment(publicID: "GHI789", testSetupID: setupID, title: "Practice Lab", dueAt: nil, isOpen: false, courseID: courseID)
        try await assignment.save(on: app.db)

        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/GHI789/edit", cookie: cookie, on: app)
        let boundary = "Boundary-Edit-Reload"
        let notebook = #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#
        let suiteConfig = """
        [
          {"source":"existing","name":"test_q1.py","tier":"public","order":1,"points":1,"displayName":"BMI check"}
        ]
        """

        try await app.asyncTest(.POST, "/instructor/GHI789/edit/save", beforeRequest: { req in
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

        try await app.asyncTest(.GET, "/instructor/GHI789/edit", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            XCTAssertTrue(html.contains("value=\"BMI check\""), html)
            XCTAssertFalse(html.contains("value=\"test_q1\""), html)
        })
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
            XCTAssertTrue(html.contains("form.addEventListener('chickadee:before-multipart-submit'"))
            XCTAssertTrue(html.contains("syncConfig();"))
            XCTAssertTrue(html.contains("chickadee:before-multipart-submit"))
        })
    }

    func testNewAssignmentPageSyncsSuiteConfigBeforeMultipartSubmit() async throws {
        _ = try await makeTestCourseID()
        let cookie = try await loginAsInstructor()

        try await app.asyncTest(.GET, "/instructor/new", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            XCTAssertTrue(html.contains("chickadee:before-multipart-submit"))
            XCTAssertTrue(html.contains("syncConfig();"))
            XCTAssertTrue(html.contains("if (e.defaultPrevented) return;"))
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
            XCTAssertTrue(body.contains("Visibility"))   // new column header (was "Tier")
            XCTAssertTrue(body.contains("support"))
        })
    }

    func testUpdateNewAssignmentDraftCreatesBlankNotebookAndRendersDraftState() async throws {
        _ = try await makeTestCourseID()
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)
        let boundary = "Boundary-New-Draft-Create"

        var redirectLocation: String?
        try await app.asyncTest(.POST, "/instructor/new/draft", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.contentType = HTTPMediaType(
                type: "multipart",
                subType: "form-data",
                parameters: ["boundary": boundary]
            )
            req.body = .init(buffer: self.multipartBody(
                boundary: boundary,
                fields: [
                    ("_csrf", csrf),
                    ("assignmentName", "Blank Draft Lab"),
                    ("draftAction", "create-assignment-notebook")
                ]
            ))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            redirectLocation = res.headers.first(name: .location)
            XCTAssertTrue((redirectLocation ?? "").contains("/instructor/new?draftID="))
        })

        let setup = try await APITestSetup.query(on: app.db).first()
        XCTAssertNotNil(setup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(setup?.notebookPath)))

        try await app.asyncTest(.GET, try XCTUnwrap(redirectLocation), beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            XCTAssertTrue(html.contains("Blank Draft Lab"))
            XCTAssertTrue(html.contains("Assignment Notebook"))  // notebook table row
            XCTAssertTrue(html.contains("Edit"))
        })
    }

    func testSaveNewAssignmentFinalizesDraftAndPersistsRequirements() async throws {
        let courseID = try await makeTestCourseID()
        app.migrations.add(CreateAssignmentRequirements())
        try await app.autoMigrate()
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

        let setupID = "setup_draft_finalize"
        let zipPath = tmpDir + "testsetups/\(setupID).zip"
        _ = try createRunnerSetupZip(suiteFiles: [], suiteConfigJSON: nil, zipPath: zipPath)
        let manifest = try makeWorkerManifestJSON(testSuites: [], includeMakefile: false, gradingMode: "worker")
        let notebookDir = tmpDir + "testsetups/notebooks/\(setupID)/"
        try FileManager.default.createDirectory(atPath: notebookDir, withIntermediateDirectories: true)
        let assignmentPath = notebookDir + "assignment.ipynb"
        try defaultNotebookData(title: "Draft Finalize").write(to: URL(fileURLWithPath: assignmentPath))
        let solutionPath = draftSolutionNotebookPath(testSetupsDirectory: tmpDir + "testsetups/", setupID: setupID)
        try defaultNotebookData(title: "Draft Finalize Solution").write(to: URL(fileURLWithPath: solutionPath))

        let setup = APITestSetup(
            id: setupID,
            manifest: manifest,
            zipPath: zipPath,
            notebookPath: assignmentPath,
            courseID: courseID
        )
        try await setup.save(on: app.db)

        let boundary = "Boundary-New-Finalize-Draft"
        try await app.asyncTest(.POST, "/instructor/new/save", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.contentType = HTTPMediaType(
                type: "multipart",
                subType: "form-data",
                parameters: ["boundary": boundary]
            )
            req.body = .init(buffer: self.multipartBody(
                boundary: boundary,
                fields: [
                    ("_csrf", csrf),
                    ("draftID", setupID),
                    ("assignmentName", "Draft-backed Lab"),
                    ("requiredLanguagesCSV", "python"),
                    ("requiredCapabilitiesCSV", "numpy, pandas")
                ]
            ))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/instructor")
        })

        let assignment = try await APIAssignment.query(on: app.db)
            .filter(\.$title == "Draft-backed Lab")
            .first()
        XCTAssertNotNil(assignment)
        let assignmentID = try XCTUnwrap(assignment?.id)

        let requirement = try await AssignmentRequirement.query(on: app.db)
            .filter(\.$assignmentID == assignmentID)
            .first()
        XCTAssertEqual(requirement?.requirementSpec.requiredLanguages.map(\.language), ["python"])
        XCTAssertEqual(requirement?.requirementSpec.requiredCapabilities.map(\.name), ["numpy", "pandas"])
    }

    func testSaveNewAssignmentRequiresCompatibleRunnerForValidation() async throws {
        let courseID = try await makeTestCourseID()
        app.migrations.add(CreateRunnerProfiles())
        app.migrations.add(CreateAssignmentRequirements())
        try await app.autoMigrate()
        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)

        let setupID = "setup_validation_runner_gate"
        let zipPath = tmpDir + "testsetups/\(setupID).zip"
        var suiteBuffer = ByteBufferAllocator().buffer(capacity: 16)
        suiteBuffer.writeString("print('ok')\n")
        _ = try createRunnerSetupZip(
            suiteFiles: [File(data: suiteBuffer, filename: "test_public.py")],
            suiteConfigJSON: nil,
            zipPath: zipPath
        )
        let manifest = try makeWorkerManifestJSON(
            testSuites: [
                ConfiguredSuiteEntry(
                    script: "test_public.py",
                    tier: "public",
                    order: 1,
                    dependsOn: [],
                    points: 1,
                    displayName: nil
                )
            ],
            includeMakefile: false,
            gradingMode: "worker"
        )
        let notebookDir = tmpDir + "testsetups/notebooks/\(setupID)/"
        try FileManager.default.createDirectory(atPath: notebookDir, withIntermediateDirectories: true)
        let assignmentPath = notebookDir + "assignment.ipynb"
        try defaultNotebookData(title: "Runner Gate").write(to: URL(fileURLWithPath: assignmentPath))
        let solutionPath = draftSolutionNotebookPath(testSetupsDirectory: tmpDir + "testsetups/", setupID: setupID)
        try defaultNotebookData(title: "Runner Gate Solution").write(to: URL(fileURLWithPath: solutionPath))

        let setup = APITestSetup(
            id: setupID,
            manifest: manifest,
            zipPath: zipPath,
            notebookPath: assignmentPath,
            courseID: courseID
        )
        try await setup.save(on: app.db)

        let boundary = "Boundary-New-Runner-Gate"
        try await app.asyncTest(.POST, "/instructor/new/save", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.contentType = HTTPMediaType(
                type: "multipart",
                subType: "form-data",
                parameters: ["boundary": boundary]
            )
            req.body = .init(buffer: self.multipartBody(
                boundary: boundary,
                fields: [
                    ("_csrf", csrf),
                    ("draftID", setupID),
                    ("assignmentName", "Needs Matplotlib"),
                    ("requiredLanguagesCSV", "python"),
                    ("requiredCapabilitiesCSV", "matplotlib")
                ]
            ))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            let location = res.headers.first(name: .location) ?? ""
            XCTAssertTrue(location.contains("/instructor/new?"))
            XCTAssertTrue(location.contains("No%20compatible%20active%20runner%20is%20available%20to%20validate%20this%20assignment."))
        })

        let assignment = try await APIAssignment.query(on: app.db)
            .filter(\.$title == "Needs Matplotlib")
            .first()
        XCTAssertNil(assignment)
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

    func testAssignmentSubmissionsUsesDisplayNameAndWaterlooTime() async throws {
        let cookie = try await loginAsInstructor()
        try await insertSetup(id: "setup_submissions_display_name")
        let assignment = try await insertAssignment(
            testSetupID: "setup_submissions_display_name",
            title: "Submission Summary",
            isOpen: true
        )
        let student = try await insertStudent(
            username: "jwallace",
            displayName: "Jim Wallace"
        )
        try await enrollStudentInTestCourse(student)

        let submission = APISubmission(
            id: "sub_display_name",
            testSetupID: "setup_submissions_display_name",
            zipPath: tmpDir + "submissions/sub_display_name.zip",
            attemptNumber: 1,
            status: "complete",
            filename: "submission.ipynb",
            userID: student.id,
            kind: APISubmission.Kind.student
        )
        try await submission.save(on: app.db)

        let persistedSubmission = try await APISubmission.find("sub_display_name", on: app.db)
        let submittedAt = try XCTUnwrap(persistedSubmission?.submittedAt)

        let expectedDate = {
            let fmt = waterlooDateTimeFormatter()
            fmt.timeStyle = .none
            return fmt.string(from: submittedAt)
        }()
        let expectedClock = {
            let fmt = waterlooDateTimeFormatter()
            fmt.dateStyle = .none
            return fmt.string(from: submittedAt)
                .replacingOccurrences(of: "\u{202F}", with: " ")
                .replacingOccurrences(of: "\u{00A0}", with: " ")
        }()

        try await app.asyncTest(.GET, "/instructor/\(assignment.publicID)/submissions", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let body = res.body.string
                .replacingOccurrences(of: "\u{202F}", with: " ")
                .replacingOccurrences(of: "\u{00A0}", with: " ")
            XCTAssertTrue(body.contains(">Wallace<"))
            XCTAssertTrue(body.contains(">Jim<"))
            XCTAssertTrue(body.contains(expectedDate))
            XCTAssertTrue(body.contains(expectedClock), "Expected clock '\(expectedClock)' in body: \(body)")
        })
    }

    // MARK: - Regression tests: assignment creation bug fixes

    /// Bug #2 regression: browser posts suiteFiles with "suiteFiles[]" field name and includes extra
    /// JSON fields in suiteConfig (source, isIncluded, dependsOn: [], displayName: null) that the
    /// server must ignore. Files must land in the zip, the manifest must list them correctly, and
    /// a validation job must be queued when at least one test suite entry is present.
    func testSaveNewAssignmentWithBrowserFormatSuiteFilesAndFieldName() async throws {
        _ = try await makeTestCourseID()
        app.migrations.add(CreateRunnerProfiles())
        app.migrations.add(CreateAssignmentRequirements())
        try await app.autoMigrate()

        // Register an active runner so the validation-runner gate passes.
        let now = Date()
        let runnerProfile = RunnerProfile()
        runnerProfile.runnerID = "runner-browser-fmt"
        runnerProfile.displayName = "Runner Browser Format"
        runnerProfile.platform = "linux"
        runnerProfile.architecture = "x86_64"
        runnerProfile.languageVersionsJSON = "[]"
        runnerProfile.capabilitiesJSON = "[]"
        runnerProfile.profileHash = nil
        runnerProfile.lastRegisteredAt = now
        runnerProfile.lastSeenAt = now
        runnerProfile.isActive = true
        try await runnerProfile.save(on: app.db)

        let cookie = try await loginAsInstructor()
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor/new", cookie: cookie, on: app)
        let boundary = "Boundary-BrowserFmt"
        let notebook = #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#

        // Exact JSON that syncConfig() produces in assignment-new.leaf:
        // extra fields (source, isIncluded) must be silently ignored by SuiteConfigRow.
        let suiteConfig = """
        [
          {"source":"upload","isIncluded":true,"isTest":true,"tier":"public","order":1,"dependsOn":[],"points":1,"displayName":null,"index":0},
          {"source":"upload","isIncluded":true,"isTest":false,"tier":"support","order":2,"dependsOn":[],"points":1,"displayName":null,"index":1}
        ]
        """

        var body = ByteBufferAllocator().buffer(capacity: 4096)
        func field(_ name: String, _ value: String) {
            body.writeString("--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.writeString(value + "\r\n")
        }
        func file(_ name: String, filename: String, contentType: String, content: String) {
            body.writeString("--\(boundary)\r\n")
            body.writeString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
            body.writeString("Content-Type: \(contentType)\r\n\r\n")
            body.writeString(content + "\r\n")
        }
        field("_csrf", csrf)
        field("assignmentName", "Browser Format Lab")
        file("assignmentNotebookFile", filename: "assignment.ipynb", contentType: "application/json", content: notebook)
        file("solutionNotebookFile",   filename: "solution.ipynb",   contentType: "application/json", content: notebook)
        // "suiteFiles[]" with brackets — exact field name sent by the browser's FormData API.
        file("suiteFiles[]", filename: "test_bmi.py", contentType: "text/plain", content: "print('test bmi')")
        file("suiteFiles[]", filename: "helpers.py",  contentType: "text/plain", content: "# helpers")
        field("suiteConfig", suiteConfig)
        body.writeString("--\(boundary)--\r\n")

        try await app.asyncTest(.POST, "/instructor/new/save", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            req.headers.contentType = HTTPMediaType(
                type: "multipart", subType: "form-data",
                parameters: ["boundary": boundary]
            )
            req.body = .init(buffer: body)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/instructor")
        })

        let assignment = try await APIAssignment.query(on: app.db)
            .filter(\.$title == "Browser Format Lab")
            .first()
        let setupID = try XCTUnwrap(assignment?.testSetupID)
        let setup   = try await APITestSetup.find(setupID, on: app.db)

        // Manifest: test_bmi.py (isTest:true, tier:public) → 1 suite entry; helpers.py → support, not listed.
        let props = try JSONDecoder().decode(
            TestProperties.self,
            from: try XCTUnwrap(setup?.manifest.data(using: .utf8))
        )
        XCTAssertEqual(props.testSuites.map(\.script), ["test_bmi.py"],
                       "test_bmi.py must be the only test suite entry in manifest")

        // Both files must be present in the zip (support files are stored even if not in manifest).
        let zipEntries = Set(listZipEntries(zipPath: try XCTUnwrap(setup?.zipPath)))
        XCTAssertTrue(zipEntries.contains("test_bmi.py"), "test_bmi.py missing from zip; entries: \(zipEntries)")
        XCTAssertTrue(zipEntries.contains("helpers.py"),  "helpers.py missing from zip; entries: \(zipEntries)")

        // Validation job must have been queued (Bug #2: was never queued when DataTransfer files
        // were absent from FormData, causing testSuites to be empty and shouldQueueValidation=false).
        XCTAssertEqual(assignment?.validationStatus, "pending")
        XCTAssertNotNil(assignment?.validationSubmissionID,
                        "validationSubmissionID must be set when suite files are present")
    }

    /// Bug #1 regression: the new assignment page must include JavaScript for the edit button
    /// on uploaded suite file rows so instructors can view/edit script content before saving.
    func testNewAssignmentPageContainsEditButtonForUploadedSuiteItems() async throws {
        _ = try await makeTestCourseID()
        let cookie = try await loginAsInstructor()

        try await app.asyncTest(.GET, "/instructor/new", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            // The rowHTML JS function must contain the edit-button class that opens the CodeMirror editor.
            XCTAssertTrue(html.contains("suite-edit-upload-btn"),
                          "New assignment page must contain suite-edit-upload-btn in rowHTML JS")
        })
    }

    /// Bug #1 regression: the edit assignment page must include JavaScript for the edit button
    /// on newly uploaded (not-yet-saved) suite file rows.
    func testEditAssignmentPageContainsEditButtonForUploadedSuiteItems() async throws {
        let courseID = try await makeTestCourseID()
        let cookie   = try await loginAsInstructor()
        let setupID  = "setup_edit_upload_btn_reg"
        let zipPath  = tmpDir + "testsetups/\(setupID).zip"
        try makeZip(at: zipPath, entries: [("test_q1.py", "print('q1')")])
        let manifest = """
        {"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[{"tier":"public","script":"test_q1.py"}],"timeLimitSeconds":10,"makefile":null}
        """
        let setup = APITestSetup(
            id: setupID, manifest: manifest, zipPath: zipPath,
            notebookPath: tmpDir + "testsetups/notebooks/\(setupID)/assignment.ipynb",
            courseID: courseID
        )
        try await setup.save(on: app.db)
        let assignment = APIAssignment(
            publicID: "RGRN01", testSetupID: setupID, title: "Edit Btn Regression",
            dueAt: nil, isOpen: false, courseID: courseID
        )
        try await assignment.save(on: app.db)

        try await app.asyncTest(.GET, "/instructor/RGRN01/edit", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            // The rowHTML JS function for new (uploaded) items must contain the edit-button class.
            XCTAssertTrue(html.contains("suite-edit-upload-btn"),
                          "Edit assignment page must contain suite-edit-upload-btn for newly uploaded suite items")
        })
    }

    /// Bug #3 regression: GET /instructor/script-templates must return a non-empty JSON dict
    /// with keys for both Python and shell template types. The edit page's fetchTemplates()
    /// now calls this endpoint (was previously broken, returning null).
    func testScriptTemplatesEndpointReturnsTemplatesForAllTypes() async throws {
        _ = try await makeTestCourseID()
        let cookie = try await loginAsInstructor()

        try await app.asyncTest(.GET, "/instructor/script-templates", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let json = try JSONDecoder().decode([String: String].self, from: Data(res.body.readableBytesView))
            // Must include at least one Python template and one shell template.
            XCTAssertTrue(json.keys.contains(where: { $0.hasPrefix("py:") }),
                          "Expected at least one py: key in script templates, got: \(json.keys.sorted())")
            XCTAssertTrue(json.keys.contains(where: { $0.hasPrefix("sh:") }),
                          "Expected at least one sh: key in script templates, got: \(json.keys.sorted())")
            // Values must be non-empty script content.
            for (key, content) in json {
                XCTAssertFalse(content.isEmpty, "Template '\(key)' must have non-empty content")
            }
        })
    }
}
