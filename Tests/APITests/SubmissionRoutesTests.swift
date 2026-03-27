// Tests/APITests/SubmissionRoutesTests.swift
//
// Integration tests for SubmissionRoutes (instructor create endpoints)
// and SubmissionDownloadRoute (authenticated download with access control).

import XCTest
import XCTVapor
@testable import chickadee_server
@testable import Core
import FluentSQLiteDriver
import Foundation

final class SubmissionRoutesTests: XCTestCase {

    private var app: Application!
    private var tmpDir: String!

    override func setUp() async throws {
        app = try await Application.make(.testing)

        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-subr-\(UUID().uuidString)/")
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

    /// Logs in as instructor and returns (sessionCookie, csrfToken).
    private func loginAsInstructor(username: String = "test_instructor") async throws -> (cookie: String, csrf: String) {
        let cookie = try await loginUser(username: username, password: "pass", role: "instructor", on: app)
        let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
        return (sessionCookie, csrf)
    }

    /// Logs in as student and returns (sessionCookie, csrfToken).
    private func loginAsStudent(username: String = "test_student") async throws -> (cookie: String, csrf: String) {
        let cookie = try await loginUser(username: username, password: "pass", role: "student", on: app)
        let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
        return (sessionCookie, csrf)
    }

    // MARK: - Data helpers

    private func makeTestCourseID() async throws -> UUID {
        if let existing = try await APICourse.query(on: app.db).filter(\.$code == "TEST101").first() {
            return try existing.requireID()
        }
        let course = APICourse(code: "TEST101", name: "Test Course")
        try await course.save(on: app.db)
        return try course.requireID()
    }

    @discardableResult
    private func ensureSetup(id: String) async throws -> APITestSetup {
        if let existing = try await APITestSetup.find(id, on: app.db) {
            return existing
        }
        let courseID = try await makeTestCourseID()
        let setup = APITestSetup(
            id: id,
            manifest: #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[{"tier":"public","script":"tests.py"}],"timeLimitSeconds":10,"makefile":null}"#,
            zipPath: tmpDir + "testsetups/\(id).zip",
            courseID: courseID
        )
        try await setup.save(on: app.db)
        return setup
    }

    private func userID(for username: String) async throws -> UUID {
        let user = try await APIUser.query(on: app.db).filter(\.$username == username).first()
        return try XCTUnwrap(user).id!
    }

    // MARK: - POST /api/v1/submissions

    func testCreateSubmissionWithValidBase64() async throws {
        let auth = try await loginAsInstructor()
        try await ensureSetup(id: "setup_001")

        let zipData = Data("PK\u{03}\u{04}fake-zip-content".utf8)
        let base64 = zipData.base64EncodedString()

        try await app.asyncTest(.POST, "/api/v1/submissions", beforeRequest: { req in
            req.headers.add(name: .cookie, value: auth.cookie)
            req.headers.add(name: "x-csrf-token", value: auth.csrf)
            try req.content.encode(CreateSubmissionBody(testSetupID: "setup_001", zipBase64: base64))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let body = try res.content.decode(SubmissionCreatedResponse.self)
            XCTAssertTrue(body.submissionID.hasPrefix("sub_"))
        })
    }

    func testCreateSubmissionWritesFileToDisk() async throws {
        let auth = try await loginAsInstructor()
        try await ensureSetup(id: "setup_disk")

        let zipData = Data("PK\u{03}\u{04}test-content-12345".utf8)
        let base64 = zipData.base64EncodedString()

        var submissionID = ""
        try await app.asyncTest(.POST, "/api/v1/submissions", beforeRequest: { req in
            req.headers.add(name: .cookie, value: auth.cookie)
            req.headers.add(name: "x-csrf-token", value: auth.csrf)
            try req.content.encode(CreateSubmissionBody(testSetupID: "setup_disk", zipBase64: base64))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            submissionID = try res.content.decode(SubmissionCreatedResponse.self).submissionID
        })

        let sub = try await APISubmission.find(submissionID, on: app.db)
        let subUnwrapped = try XCTUnwrap(sub)
        let fileData = try Data(contentsOf: URL(fileURLWithPath: subUnwrapped.zipPath))
        XCTAssertEqual(fileData, zipData)
    }

    func testCreateSubmissionIncrementsAttemptNumber() async throws {
        let auth = try await loginAsInstructor()
        try await ensureSetup(id: "setup_inc")

        let base64 = Data("PK".utf8).base64EncodedString()

        // First submission
        try await app.asyncTest(.POST, "/api/v1/submissions", beforeRequest: { req in
            req.headers.add(name: .cookie, value: auth.cookie)
            req.headers.add(name: "x-csrf-token", value: auth.csrf)
            try req.content.encode(CreateSubmissionBody(testSetupID: "setup_inc", zipBase64: base64))
        }, afterResponse: { _ in })

        // Second submission
        var secondID = ""
        try await app.asyncTest(.POST, "/api/v1/submissions", beforeRequest: { req in
            req.headers.add(name: .cookie, value: auth.cookie)
            req.headers.add(name: "x-csrf-token", value: auth.csrf)
            try req.content.encode(CreateSubmissionBody(testSetupID: "setup_inc", zipBase64: base64))
        }, afterResponse: { res in
            secondID = try res.content.decode(SubmissionCreatedResponse.self).submissionID
        })

        let sub = try await APISubmission.find(secondID, on: app.db)
        XCTAssertEqual(try XCTUnwrap(sub).attemptNumber, 2)
    }

    func testCreateSubmissionRejectsBadSetupID() async throws {
        let auth = try await loginAsInstructor()

        let base64 = Data("PK".utf8).base64EncodedString()
        try await app.asyncTest(.POST, "/api/v1/submissions", beforeRequest: { req in
            req.headers.add(name: .cookie, value: auth.cookie)
            req.headers.add(name: "x-csrf-token", value: auth.csrf)
            try req.content.encode(CreateSubmissionBody(testSetupID: "nonexistent", zipBase64: base64))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    func testCreateSubmissionRejectsInvalidBase64() async throws {
        let auth = try await loginAsInstructor()
        try await ensureSetup(id: "setup_b64")

        try await app.asyncTest(.POST, "/api/v1/submissions", beforeRequest: { req in
            req.headers.add(name: .cookie, value: auth.cookie)
            req.headers.add(name: "x-csrf-token", value: auth.csrf)
            try req.content.encode(CreateSubmissionBody(testSetupID: "setup_b64", zipBase64: "!!!not-base64!!!"))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    func testCreateSubmissionRequiresInstructorRole() async throws {
        let auth = try await loginAsStudent()
        try await ensureSetup(id: "setup_role")

        let base64 = Data("PK".utf8).base64EncodedString()
        try await app.asyncTest(.POST, "/api/v1/submissions", beforeRequest: { req in
            req.headers.add(name: .cookie, value: auth.cookie)
            req.headers.add(name: "x-csrf-token", value: auth.csrf)
            try req.content.encode(CreateSubmissionBody(testSetupID: "setup_role", zipBase64: base64))
        }, afterResponse: { res in
            XCTAssertTrue([.forbidden, .unauthorized].contains(res.status),
                "Expected 401 or 403, got \(res.status)")
        })
    }

    // MARK: - POST /api/v1/submissions/file

    func testCreateSubmissionFileWithPython() async throws {
        let auth = try await loginAsInstructor()
        try await ensureSetup(id: "setup_py")

        let pyContent = Data("print('hello')".utf8)
        try await app.asyncTest(.POST, "/api/v1/submissions/file", beforeRequest: { req in
            req.headers.add(name: .cookie, value: auth.cookie)
            req.headers.add(name: "x-csrf-token", value: auth.csrf)
            try req.content.encode(SubmitFileBody(testSetupID: "setup_py", filename: "solution.py", file: pyContent))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let body = try res.content.decode(SubmissionCreatedResponse.self)
            XCTAssertTrue(body.submissionID.hasPrefix("sub_"))
        })
    }

    func testCreateSubmissionFileSavesWithCorrectExtension() async throws {
        let auth = try await loginAsInstructor()
        try await ensureSetup(id: "setup_ext")

        let content = Data("x = 1".utf8)
        var subID = ""
        try await app.asyncTest(.POST, "/api/v1/submissions/file", beforeRequest: { req in
            req.headers.add(name: .cookie, value: auth.cookie)
            req.headers.add(name: "x-csrf-token", value: auth.csrf)
            try req.content.encode(SubmitFileBody(testSetupID: "setup_ext", filename: "homework.py", file: content))
        }, afterResponse: { res in
            subID = try res.content.decode(SubmissionCreatedResponse.self).submissionID
        })

        let sub = try await APISubmission.find(subID, on: app.db)
        let path = try XCTUnwrap(sub).zipPath
        XCTAssertTrue(path.hasSuffix(".py"), "Expected .py extension, got \(path)")
        XCTAssertEqual(try XCTUnwrap(sub).filename, "homework.py")
    }

    func testCreateSubmissionFileRejectsBadSetupID() async throws {
        let auth = try await loginAsInstructor()

        try await app.asyncTest(.POST, "/api/v1/submissions/file", beforeRequest: { req in
            req.headers.add(name: .cookie, value: auth.cookie)
            req.headers.add(name: "x-csrf-token", value: auth.csrf)
            try req.content.encode(SubmitFileBody(testSetupID: "bogus", filename: "test.py", file: Data("x".utf8)))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .badRequest)
        })
    }

    // MARK: - GET /api/v1/submissions/:id/download

    func testDownloadAsOwner() async throws {
        let auth = try await loginAsStudent(username: "dl_owner")
        let ownerID = try await userID(for: "dl_owner")
        try await ensureSetup(id: "setup_dl")

        let sub = APISubmission(
            id: "sub_dl_own",
            testSetupID: "setup_dl",
            zipPath: tmpDir + "submissions/sub_dl_own.zip",
            attemptNumber: 1,
            userID: ownerID
        )
        try await sub.save(on: app.db)

        let fileContent = Data("fake-zip-bytes".utf8)
        try fileContent.write(to: URL(fileURLWithPath: sub.zipPath))

        try await app.asyncTest(.GET, "/api/v1/submissions/sub_dl_own/download", beforeRequest: { req in
            req.headers.add(name: .cookie, value: auth.cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(Data(res.body.readableBytesView), fileContent)
        })
    }

    func testDownloadAsInstructorForAnySubmission() async throws {
        let studentAuth = try await loginAsStudent(username: "dl_student2")
        let studentID = try await userID(for: "dl_student2")
        let instrAuth = try await loginAsInstructor(username: "dl_instructor")
        _ = studentAuth

        try await ensureSetup(id: "setup_dl2")
        let sub = APISubmission(
            id: "sub_dl_instr",
            testSetupID: "setup_dl2",
            zipPath: tmpDir + "submissions/sub_dl_instr.zip",
            attemptNumber: 1,
            userID: studentID
        )
        try await sub.save(on: app.db)
        try Data("instructor-download".utf8).write(to: URL(fileURLWithPath: sub.zipPath))

        try await app.asyncTest(.GET, "/api/v1/submissions/sub_dl_instr/download", beforeRequest: { req in
            req.headers.add(name: .cookie, value: instrAuth.cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(Data(res.body.readableBytesView), Data("instructor-download".utf8))
        })
    }

    func testDownloadForbiddenForNonOwnerStudent() async throws {
        let authA = try await loginAsStudent(username: "dl_studentA")
        let idA = try await userID(for: "dl_studentA")
        _ = authA

        try await ensureSetup(id: "setup_dl3")
        let sub = APISubmission(
            id: "sub_dl_forbid",
            testSetupID: "setup_dl3",
            zipPath: tmpDir + "submissions/sub_dl_forbid.zip",
            attemptNumber: 1,
            userID: idA
        )
        try await sub.save(on: app.db)
        try Data("private".utf8).write(to: URL(fileURLWithPath: sub.zipPath))

        let authB = try await loginAsStudent(username: "dl_studentB")
        try await app.asyncTest(.GET, "/api/v1/submissions/sub_dl_forbid/download", beforeRequest: { req in
            req.headers.add(name: .cookie, value: authB.cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .forbidden)
        })
    }

    func testDownloadNotFoundForMissingSubmission() async throws {
        let auth = try await loginAsInstructor()

        try await app.asyncTest(.GET, "/api/v1/submissions/nonexistent/download", beforeRequest: { req in
            req.headers.add(name: .cookie, value: auth.cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    func testDownloadUsesCustomFilename() async throws {
        let auth = try await loginAsInstructor(username: "dl_fname_instr")
        try await ensureSetup(id: "setup_fname")

        let sub = APISubmission(
            id: "sub_dl_fname",
            testSetupID: "setup_fname",
            zipPath: tmpDir + "submissions/sub_dl_fname.ipynb",
            attemptNumber: 1,
            filename: "my_notebook.ipynb"
        )
        try await sub.save(on: app.db)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: sub.zipPath))

        try await app.asyncTest(.GET, "/api/v1/submissions/sub_dl_fname/download", beforeRequest: { req in
            req.headers.add(name: .cookie, value: auth.cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let disposition = res.headers.first(name: .contentDisposition) ?? ""
            XCTAssertTrue(disposition.contains("my_notebook.ipynb"),
                "Expected filename in Content-Disposition, got: \(disposition)")
        })
    }
}
