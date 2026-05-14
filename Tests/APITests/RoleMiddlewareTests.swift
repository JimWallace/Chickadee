// Tests/APITests/RoleMiddlewareTests.swift
//
// Integration tests for RoleMiddleware — verifies redirect vs 401 for
// unauthenticated requests, and 403 for insufficient-role requests.

import XCTest
import XCTVapor
@testable import chickadee_server
import Fluent
import Foundation

final class RoleMiddlewareTests: XCTestCase {

    private var app: Application!

    override func setUp() async throws {
        app = try await makeTestApp(prefix: "chickadee-role")

        // Register lightweight test-only routes with each protection level.
        // Browser-style paths (no /api/ prefix) → unauthenticated → 303 /login.
        // API-style paths (/api/ prefix)          → unauthenticated → 401.
        let sessionAuth = UserSessionAuthenticator()

        app.grouped(sessionAuth, RoleMiddleware(required: .authenticated))
            .get("__test_auth") { _ in "auth-ok" }

        app.grouped(sessionAuth, RoleMiddleware(required: .instructor))
            .get("__test_instructor") { _ in "instructor-ok" }

        app.grouped(sessionAuth, RoleMiddleware(required: .admin))
            .get("__test_admin") { _ in "admin-ok" }

        // API-prefixed equivalents to exercise the 401 (non-browser) path.
        app.grouped(sessionAuth, RoleMiddleware(required: .instructor))
            .get("api", "__test_instructor") { _ in "api-instructor-ok" }

        app.grouped(sessionAuth, RoleMiddleware(required: .admin))
            .get("api", "__test_admin") { _ in "api-admin-ok" }
    }

    override func tearDown() async throws {
        try await app.tearDownTestApp()
    }

    // MARK: - Unauthenticated

    func testUnauthenticated_browserRoute_redirectsToLogin() throws {
        try app.test(.GET, "/__test_auth") { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/login")
        }
    }

    func testUnauthenticated_apiRoute_returns401() throws {
        try app.test(.GET, "/api/__test_instructor") { res in
            XCTAssertEqual(res.status, .unauthorized)
        }
    }

    func testUnauthenticated_adminApiRoute_returns401() throws {
        try app.test(.GET, "/api/__test_admin") { res in
            XCTAssertEqual(res.status, .unauthorized)
        }
    }

    // MARK: - Student role

    func testStudent_authenticatedRoute_returns200() async throws {
        let cookie = try await loginUser(username: "role_student", password: "pw",
                                         role: "student", on: app)
        try await app.asyncTest(.GET, "/__test_auth", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.body.string, "auth-ok")
        })
    }

    func testStudent_instructorRoute_returns403() async throws {
        let cookie = try await loginUser(username: "role_student2", password: "pw",
                                         role: "student", on: app)
        try await app.asyncTest(.GET, "/__test_instructor", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .forbidden)
        })
    }

    func testStudent_adminRoute_returns403() async throws {
        let cookie = try await loginUser(username: "role_student3", password: "pw",
                                         role: "student", on: app)
        try await app.asyncTest(.GET, "/__test_admin", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .forbidden)
        })
    }

    // MARK: - Instructor role

    func testInstructor_authenticatedRoute_returns200() async throws {
        let cookie = try await loginUser(username: "role_instructor", password: "pw",
                                         role: "instructor", on: app)
        try await app.asyncTest(.GET, "/__test_auth", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })
    }

    func testInstructor_instructorRoute_returns200() async throws {
        let cookie = try await loginUser(username: "role_instructor2", password: "pw",
                                         role: "instructor", on: app)
        try await app.asyncTest(.GET, "/__test_instructor", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.body.string, "instructor-ok")
        })
    }

    func testInstructor_adminRoute_returns403() async throws {
        let cookie = try await loginUser(username: "role_instructor3", password: "pw",
                                         role: "instructor", on: app)
        try await app.asyncTest(.GET, "/__test_admin", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .forbidden)
        })
    }

    // MARK: - Admin role

    func testAdmin_authenticatedRoute_returns200() async throws {
        let cookie = try await loginUser(username: "role_admin", password: "pw",
                                         role: "admin", on: app)
        try await app.asyncTest(.GET, "/__test_auth", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })
    }

    func testAdmin_instructorRoute_returns200() async throws {
        // Admin implies instructor — should be granted access.
        let cookie = try await loginUser(username: "role_admin2", password: "pw",
                                         role: "admin", on: app)
        try await app.asyncTest(.GET, "/__test_instructor", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.body.string, "instructor-ok")
        })
    }

    func testAdmin_adminRoute_returns200() async throws {
        let cookie = try await loginUser(username: "role_admin3", password: "pw",
                                         role: "admin", on: app)
        try await app.asyncTest(.GET, "/__test_admin", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.body.string, "admin-ok")
        })
    }
}
