// Tests/APITests/CSRFTests.swift
//
// Integration tests for CSRF token validation on both URL-encoded and
// multipart form submissions.

import XCTest
import XCTVapor
@testable import chickadee_server
import FluentSQLiteDriver
import Foundation

final class CSRFTests: XCTestCase {

    private var app: Application!
    private var tmpDir: String!

    override func setUp() async throws {
        app = Application(.testing)

        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-csrf-\(UUID().uuidString)/")
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
        try await app.autoMigrate().get()

        configureLeaf(app)
        try routes(app)
    }

    override func tearDown() async throws {
        app.shutdown()
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    // MARK: - URL-encoded form (login)

    func testLoginWithoutCSRFTokenIsForbidden() async throws {
        try await app.test(.POST, "/login", beforeRequest: { req in
            try req.content.encode(["username": "anyone", "password": "whatever"],
                                   as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .forbidden)
        })
    }

    func testLoginWithInvalidCSRFTokenIsForbidden() async throws {
        // Obtain a real session cookie (so the session exists server-side)
        // but supply a made-up token that doesn't match.
        let (_, sessionCookie) = try await csrfFields(for: "/login", on: app)
        try await app.test(.POST, "/login", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(
                ["username": "anyone", "password": "whatever", "_csrf": "not-a-real-token"],
                as: .urlEncodedForm
            )
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .forbidden)
        })
    }

    func testLoginWithValidCSRFTokenSucceeds() async throws {
        let hash = try Bcrypt.hash("pass1234")
        let user = APIUser(username: "csrfuser", passwordHash: hash, role: "student")
        try await user.save(on: app.db)

        let (token, sessionCookie) = try await csrfFields(for: "/login", on: app)
        try await app.test(.POST, "/login", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(
                ["username": "csrfuser", "password": "pass1234", "_csrf": token],
                as: .urlEncodedForm
            )
        }, afterResponse: { res in
            // Successful login redirects; any non-403 means CSRF passed.
            XCTAssertNotEqual(res.status, .forbidden)
            XCTAssertEqual(res.status, .seeOther)
        })
    }

    // MARK: - Multipart form (file submission)

    /// Seeds a course + test setup and returns the setup ID.
    private func seedSetup(courseCode: String, setupID: String) async throws {
        let course = APICourse(code: courseCode, name: "\(courseCode) Course")
        try await course.save(on: app.db)

        let zipPath = tmpDir + "testsetups/\(setupID).zip"
        let emptyZip = Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))
        try emptyZip.write(to: URL(fileURLWithPath: zipPath))

        let manifest = """
        {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10,"makefile":null}
        """
        let setup = APITestSetup(
            id: setupID, manifest: manifest, zipPath: zipPath,
            courseID: try course.requireID()
        )
        try await setup.save(on: app.db)
    }

    /// Builds a minimal multipart body with an optional `_csrf` field and a
    /// small Python file, using the given `boundary`.
    private func multipartBody(boundary: String, csrfToken: String?) -> ByteBuffer {
        var buf = ByteBufferAllocator().buffer(capacity: 1024)

        if let token = csrfToken {
            buf.writeString("--\(boundary)\r\n")
            buf.writeString("Content-Disposition: form-data; name=\"_csrf\"\r\n\r\n")
            buf.writeString(token)
            buf.writeString("\r\n")
        }

        buf.writeString("--\(boundary)\r\n")
        buf.writeString("Content-Disposition: form-data; name=\"files\"; filename=\"solution.py\"\r\n")
        buf.writeString("Content-Type: text/x-python\r\n\r\n")
        buf.writeString("x = 42\n")
        buf.writeString("\r\n")
        buf.writeString("--\(boundary)--\r\n")
        return buf
    }

    func testMultipartSubmitWithoutCSRFTokenIsForbidden() async throws {
        let setupID = "setup_csrf_no_tok"
        try await seedSetup(courseCode: "CS201", setupID: setupID)
        let cookie = try await loginUser(username: "student_no_tok", password: "pass1234",
                                        role: "student", on: app)

        let boundary = "Boundary-NoToken"
        let buf = multipartBody(boundary: boundary, csrfToken: nil)

        try await app.test(.POST, "/testsetups/\(setupID)/submit", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
            req.headers.contentType = HTTPMediaType(
                type: "multipart", subType: "form-data",
                parameters: ["boundary": boundary]
            )
            req.body = buf
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .forbidden,
                           "Multipart POST without _csrf must be rejected by CSRF middleware")
        })
    }

    func testMultipartSubmitWithInvalidCSRFTokenIsForbidden() async throws {
        let setupID = "setup_csrf_bad_tok"
        try await seedSetup(courseCode: "CS202", setupID: setupID)
        let cookie = try await loginUser(username: "student_bad_tok", password: "pass1234",
                                        role: "student", on: app)

        let boundary = "Boundary-BadToken"
        let buf = multipartBody(boundary: boundary, csrfToken: "completely-wrong-token")

        try await app.test(.POST, "/testsetups/\(setupID)/submit", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
            req.headers.contentType = HTTPMediaType(
                type: "multipart", subType: "form-data",
                parameters: ["boundary": boundary]
            )
            req.body = buf
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .forbidden,
                           "Multipart POST with wrong _csrf must be rejected by CSRF middleware")
        })
    }

    func testMultipartSubmitWithValidCSRFTokenPassesCSRFMiddleware() async throws {
        let setupID = "setup_csrf_ok_tok"
        try await seedSetup(courseCode: "CS203", setupID: setupID)
        let cookie = try await loginUser(username: "student_ok_tok", password: "pass1234",
                                        role: "student", on: app)

        // GET the submit page to obtain a session-bound CSRF token.
        let (token, _) = try await csrfFields(
            for: "/testsetups/\(setupID)/submit", cookie: cookie, on: app
        )
        XCTAssertFalse(token.isEmpty, "Expected a CSRF token in the rendered submit form")

        let boundary = "Boundary-GoodToken"
        let buf = multipartBody(boundary: boundary, csrfToken: token)

        try await app.test(.POST, "/testsetups/\(setupID)/submit", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
            req.headers.contentType = HTTPMediaType(
                type: "multipart", subType: "form-data",
                parameters: ["boundary": boundary]
            )
            req.body = buf
        }, afterResponse: { res in
            // CSRF middleware passed — any response other than 403 is correct here.
            // (Business logic may redirect or error for other reasons.)
            XCTAssertNotEqual(res.status, .forbidden,
                              "Valid multipart CSRF token must not be rejected by CSRF middleware")
        })
    }
}
