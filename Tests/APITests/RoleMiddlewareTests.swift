// Tests/APITests/RoleMiddlewareTests.swift
//
// Integration tests for RoleMiddleware — verifies redirect vs 401 for
// unauthenticated requests, and 403 for insufficient-role requests.

import Fluent
import Foundation
import Testing
import XCTVapor

@testable import chickadee_server

@Suite struct RoleMiddlewareTests {

    private func makeApp() async throws -> Application {
        let app = try await makeTestApp(prefix: "chickadee-role")

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

        return app
    }

    // MARK: - Unauthenticated

    @Test func unauthenticated_browserRoute_redirectsToLogin() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(.GET, "/__test_auth") { res in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "/login")
            }
        }
    }

    @Test func unauthenticated_apiRoute_returns401() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(.GET, "/api/__test_instructor") { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test func unauthenticated_adminApiRoute_returns401() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(.GET, "/api/__test_admin") { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    // MARK: - Student role

    @Test func student_authenticatedRoute_returns200() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginUser(
                username: "role_student", password: "pw",
                role: "student", on: app)
            try await app.asyncTest(
                .GET, "/__test_auth",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string == "auth-ok")
                })

        }
    }

    @Test func student_instructorRoute_returns403() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginUser(
                username: "role_student2", password: "pw",
                role: "student", on: app)
            try await app.asyncTest(
                .GET, "/__test_instructor",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })

        }
    }

    @Test func student_adminRoute_returns403() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginUser(
                username: "role_student3", password: "pw",
                role: "student", on: app)
            try await app.asyncTest(
                .GET, "/__test_admin",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })

        }
    }

    // MARK: - Instructor role

    @Test func instructor_authenticatedRoute_returns200() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginUser(
                username: "role_instructor", password: "pw",
                role: "instructor", on: app)
            try await app.asyncTest(
                .GET, "/__test_auth",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                })

        }
    }

    @Test func instructor_instructorRoute_returns200() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginUser(
                username: "role_instructor2", password: "pw",
                role: "instructor", on: app)
            try await app.asyncTest(
                .GET, "/__test_instructor",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string == "instructor-ok")
                })

        }
    }

    @Test func instructor_adminRoute_returns403() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginUser(
                username: "role_instructor3", password: "pw",
                role: "instructor", on: app)
            try await app.asyncTest(
                .GET, "/__test_admin",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })

        }
    }

    // MARK: - Admin role

    @Test func admin_authenticatedRoute_returns200() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginUser(
                username: "role_admin", password: "pw",
                role: "admin", on: app)
            try await app.asyncTest(
                .GET, "/__test_auth",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                })

        }
    }

    @Test func admin_instructorRoute_returns200() async throws {
        try await withApp(try await makeApp()) { app in
            // Admin implies instructor — should be granted access.
            let cookie = try await loginUser(
                username: "role_admin2", password: "pw",
                role: "admin", on: app)
            try await app.asyncTest(
                .GET, "/__test_instructor",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string == "instructor-ok")
                })

        }
    }

    @Test func admin_adminRoute_returns200() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginUser(
                username: "role_admin3", password: "pw",
                role: "admin", on: app)
            try await app.asyncTest(
                .GET, "/__test_admin",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string == "admin-ok")
                })

        }
    }
}
