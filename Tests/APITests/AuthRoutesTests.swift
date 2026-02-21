// Tests/APITests/AuthRoutesTests.swift
//
// Integration tests for Phase 6 authentication routes.

import XCTest
import XCTVapor
@testable import chickadee_server
import FluentSQLiteDriver
import Foundation

final class AuthRoutesTests: XCTestCase {

    private var app: Application!
    private var tmpDir: String!

    override func setUp() async throws {
        app = Application(.testing)

        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-auth-\(UUID().uuidString)", isDirectory: true)
            .path + "/"

        let dirs = ["results/", "testsetups/", "submissions/"].map { tmpDir + $0 }
        for dir in dirs { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        app.resultsDirectory     = dirs[0]
        app.testSetupsDirectory  = dirs[1]
        app.submissionsDirectory = dirs[2]

        // Sessions required for auth routes.
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
        try await app.autoMigrate().get()

        try routes(app)
    }

    override func tearDown() async throws {
        app.shutdown()
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    // MARK: - Registration

    func testRegisterFirstUserBecomesAdmin() async throws {
        try await app.test(.POST, "/register", beforeRequest: { req in
            try req.content.encode(["username": "jim", "password": "secret123"], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/")
        })

        let user = try await APIUser.query(on: app.db).first()
        XCTAssertNotNil(user)
        XCTAssertEqual(user?.username, "jim")
        XCTAssertEqual(user?.role, "admin")
    }

    func testRegisterSecondUserBecomesStudent() async throws {
        // Seed an existing admin.
        let hash = try Bcrypt.hash("password1")
        let admin = APIUser(username: "admin", passwordHash: hash, role: "admin")
        try await admin.save(on: app.db)

        try await app.test(.POST, "/register", beforeRequest: { req in
            try req.content.encode(["username": "student1", "password": "password2"], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
        })

        let student = try await APIUser.query(on: app.db)
            .filter(\.$username == "student1")
            .first()
        XCTAssertEqual(student?.role, "student")
    }

    func testRegisterDuplicateUsernameRedirectsWithError() async throws {
        let hash = try Bcrypt.hash("password1")
        let existing = APIUser(username: "jim", passwordHash: hash, role: "admin")
        try await existing.save(on: app.db)

        try await app.test(.POST, "/register", beforeRequest: { req in
            try req.content.encode(["username": "jim", "password": "password2"], as: .urlEncodedForm)
        }, afterResponse: { res in
            // PRG: redirect back to form with error param.
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/register?error=taken")
        })
    }

    func testRegisterShortPasswordRedirectsWithError() async throws {
        try await app.test(.POST, "/register", beforeRequest: { req in
            try req.content.encode(["username": "jim", "password": "short"], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/register?error=password_short")
        })
    }

    // MARK: - Login

    func testLoginWithCorrectCredentialsRedirects() async throws {
        let hash = try Bcrypt.hash("mypassword")
        let user = APIUser(username: "jim", passwordHash: hash, role: "admin")
        try await user.save(on: app.db)

        try await app.test(.POST, "/login", beforeRequest: { req in
            try req.content.encode(["username": "jim", "password": "mypassword"], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/")
            // Session cookie should be set.
            XCTAssertNotNil(res.headers.first(name: .setCookie))
        })
    }

    func testLoginWithWrongPasswordRedirectsWithError() async throws {
        let hash = try Bcrypt.hash("mypassword")
        let user = APIUser(username: "jim", passwordHash: hash, role: "admin")
        try await user.save(on: app.db)

        try await app.test(.POST, "/login", beforeRequest: { req in
            try req.content.encode(["username": "jim", "password": "wrong"], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/login?error=invalid")
        })
    }

    func testLoginWithUnknownUserRedirectsWithError() async throws {
        try await app.test(.POST, "/login", beforeRequest: { req in
            try req.content.encode(["username": "nobody", "password": "password"], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/login?error=invalid")
        })
    }

    // MARK: - Access control

    func testUnauthenticatedHomeRedirectsToLogin() async throws {
        try await app.test(.GET, "/", afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/login")
        })
    }

    func testStudentCannotAccessTestSetupNew() async throws {
        // Create a student, get a session cookie, then try to access instructor-only page.
        let hash = try Bcrypt.hash("pass1234")
        let student = APIUser(username: "student", passwordHash: hash, role: "student")
        try await student.save(on: app.db)

        var sessionCookie = ""
        try await app.test(.POST, "/login", beforeRequest: { req in
            try req.content.encode(["username": "student", "password": "pass1234"], as: .urlEncodedForm)
        }, afterResponse: { res in
            // Extract session cookie for subsequent requests.
            sessionCookie = res.headers.first(name: .setCookie) ?? ""
        })

        try await app.test(.GET, "/testsetups/new", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .forbidden)
        })
    }

    func testStudentCannotAccessAdminPage() async throws {
        let hash = try Bcrypt.hash("pass1234")
        let student = APIUser(username: "student", passwordHash: hash, role: "student")
        try await student.save(on: app.db)

        var sessionCookie = ""
        try await app.test(.POST, "/login", beforeRequest: { req in
            try req.content.encode(["username": "student", "password": "pass1234"], as: .urlEncodedForm)
        }, afterResponse: { res in
            sessionCookie = res.headers.first(name: .setCookie) ?? ""
        })

        try await app.test(.GET, "/admin", beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .forbidden)
        })
    }
}
