// Tests/APITests/AuthRoutesTests.swift
//
// Integration tests for Phase 6 authentication routes.

import Fluent
import Foundation
import XCTVapor
import XCTest

@testable import chickadee_server

final class AuthRoutesTests: XCTestCase {

    private var app: Application!

    override func setUp() async throws {
        app = try await makeTestApp(prefix: "chickadee-auth")
    }

    override func tearDown() async throws {
        try await app.tearDownTestApp()
    }

    // MARK: - Registration

    func testRegisterFirstUserBecomesAdmin() async throws {
        let (token, cookie) = try await csrfFields(for: "/register", on: app)
        try await app.asyncTest(
            .POST, "/register",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                try req.content.encode(
                    ["username": "jim", "password": "secret123", "_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
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

        let (token, cookie) = try await csrfFields(for: "/register", on: app)
        try await app.asyncTest(
            .POST, "/register",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                try req.content.encode(
                    ["username": "student1", "password": "password2", "_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
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

        let (token, cookie) = try await csrfFields(for: "/register", on: app)
        try await app.asyncTest(
            .POST, "/register",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                try req.content.encode(
                    ["username": "jim", "password": "password2", "_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
                // PRG: redirect back to form with error param.
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertEqual(res.headers.first(name: .location), "/register?error=taken")
            })
    }

    func testRegisterShortPasswordRedirectsWithError() async throws {
        let (token, cookie) = try await csrfFields(for: "/register", on: app)
        try await app.asyncTest(
            .POST, "/register",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                try req.content.encode(["username": "jim", "password": "short", "_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertEqual(res.headers.first(name: .location), "/register?error=password_short")
            })
    }

    // MARK: - Login

    func testLoginWithCorrectCredentialsRedirects() async throws {
        let hash = try Bcrypt.hash("mypassword")
        let user = APIUser(username: "jim", passwordHash: hash, role: "admin")
        try await user.save(on: app.db)

        let (token, cookie) = try await csrfFields(for: "/login", on: app)
        try await app.asyncTest(
            .POST, "/login",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                try req.content.encode(
                    ["username": "jim", "password": "mypassword", "_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
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

        let (token, cookie) = try await csrfFields(for: "/login", on: app)
        try await app.asyncTest(
            .POST, "/login",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                try req.content.encode(["username": "jim", "password": "wrong", "_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertEqual(res.headers.first(name: .location), "/login?error=invalid")
            })
    }

    func testLoginWithUnknownUserRedirectsWithError() async throws {
        let (token, cookie) = try await csrfFields(for: "/login", on: app)
        try await app.asyncTest(
            .POST, "/login",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                try req.content.encode(
                    ["username": "nobody", "password": "password", "_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertEqual(res.headers.first(name: .location), "/login?error=invalid")
            })
    }

    // MARK: - Access control

    func testUnauthenticatedHomeRedirectsToLogin() async throws {
        try await app.asyncTest(
            .GET, "/",
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertEqual(res.headers.first(name: .location), "/login")
            })
    }

    func testStudentCannotAccessTestSetupNew() async throws {
        // Create a student, get a session cookie, then try to access instructor-only page.
        let hash = try Bcrypt.hash("pass1234")
        let student = APIUser(username: "student", passwordHash: hash, role: "student")
        try await student.save(on: app.db)

        let sessionCookie = try await loginUser(username: "student", password: "pass1234", role: "student", on: app)

        try await app.asyncTest(
            .GET, "/testsetups/new",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .forbidden)
            })
    }

    func testStudentCannotAccessAdminPage() async throws {
        let hash = try Bcrypt.hash("pass1234")
        let student = APIUser(username: "student", passwordHash: hash, role: "student")
        try await student.save(on: app.db)

        let sessionCookie = try await loginUser(username: "student", password: "pass1234", role: "student", on: app)

        try await app.asyncTest(
            .GET, "/admin",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .forbidden)
            })
    }

    func testStudentCannotAccessAssignmentsPage() async throws {
        let hash = try Bcrypt.hash("pass1234")
        let student = APIUser(username: "student2", passwordHash: hash, role: "student")
        try await student.save(on: app.db)

        let sessionCookie = try await loginUser(username: "student2", password: "pass1234", role: "student", on: app)

        try await app.asyncTest(
            .GET, "/instructor",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: sessionCookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .forbidden)
            })
    }
}
