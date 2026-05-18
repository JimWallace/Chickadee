// Tests/APITests/AuthRoutesTests.swift
//
// Integration tests for Phase 6 authentication routes.

import Fluent
import Foundation
import Testing
import XCTVapor

@testable import chickadee_server

@Suite struct AuthRoutesTests {

    private func makeApp() async throws -> Application {
        let app = try await makeTestApp(prefix: "chickadee-auth")
        return app
    }

    // MARK: - Registration

    @Test func registerFirstUserBecomesAdmin() async throws {
        try await withApp(try await makeApp()) { app in
            let (token, cookie) = try await csrfFields(for: "/register", on: app)
            try await app.asyncTest(
                .POST, "/register",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    try req.content.encode(
                        ["username": "jim", "password": "secret123", "_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/")
                })

            let user = try await APIUser.query(on: app.db).first()
            #expect(user != nil)
            #expect(user?.username == "jim")
            #expect(user?.role == "admin")

        }
    }

    @Test func registerSecondUserBecomesStudent() async throws {
        try await withApp(try await makeApp()) { app in
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
                    #expect(res.status == .seeOther)
                })

            let student = try await APIUser.query(on: app.db)
                .filter(\.$username == "student1")
                .first()
            #expect(student?.role == "student")

        }
    }

    @Test func registerDuplicateUsernameRedirectsWithError() async throws {
        try await withApp(try await makeApp()) { app in
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
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/register?error=taken")
                })

        }
    }

    @Test func registerShortPasswordRedirectsWithError() async throws {
        try await withApp(try await makeApp()) { app in
            let (token, cookie) = try await csrfFields(for: "/register", on: app)
            try await app.asyncTest(
                .POST, "/register",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    try req.content.encode(
                        ["username": "jim", "password": "short", "_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/register?error=password_short")
                })

        }
    }

    // MARK: - Login

    @Test func loginWithCorrectCredentialsRedirects() async throws {
        try await withApp(try await makeApp()) { app in
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
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/")
                    // Session cookie should be set.
                    #expect(res.headers.first(name: .setCookie) != nil)
                })

        }
    }

    @Test func loginWithWrongPasswordRedirectsWithError() async throws {
        try await withApp(try await makeApp()) { app in
            let hash = try Bcrypt.hash("mypassword")
            let user = APIUser(username: "jim", passwordHash: hash, role: "admin")
            try await user.save(on: app.db)

            let (token, cookie) = try await csrfFields(for: "/login", on: app)
            try await app.asyncTest(
                .POST, "/login",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    try req.content.encode(
                        ["username": "jim", "password": "wrong", "_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/login?error=invalid")
                })

        }
    }

    @Test func loginWithUnknownUserRedirectsWithError() async throws {
        try await withApp(try await makeApp()) { app in
            let (token, cookie) = try await csrfFields(for: "/login", on: app)
            try await app.asyncTest(
                .POST, "/login",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    try req.content.encode(
                        ["username": "nobody", "password": "password", "_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/login?error=invalid")
                })

        }
    }

    @Test func loginWithUnknownUserStillRunsBcryptVerify() async throws {
        try await withApp(try await makeApp()) { app in
            // Regression for issue #559 (account-enumeration timing).  The
            // user-not-found path must run a bcrypt verify against a dummy
            // hash so its wall-clock time matches the user-found-wrong-
            // password path.  bcrypt cost 12 takes ≥100 ms on any reasonable
            // host; without the equalizer the miss returns in <10 ms.
            //
            // Warm-up POST primes the timing-equalizer hash cache so we
            // measure verify time, not the one-shot hash+verify cost of the
            // first-ever miss.
            let warmupCSRF = try await csrfFields(for: "/login", on: app)
            try await app.asyncTest(
                .POST, "/login",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: warmupCSRF.1)
                    try req.content.encode(
                        ["username": "warmup_user", "password": "x", "_csrf": warmupCSRF.0],
                        as: .urlEncodedForm)
                }, afterResponse: { _ in })

            let (token, cookie) = try await csrfFields(for: "/login", on: app)
            let start = Date()
            try await app.asyncTest(
                .POST, "/login",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    try req.content.encode(
                        ["username": "still_no_such_user", "password": "x", "_csrf": token],
                        as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertGreaterThan(
                elapsed, 0.05,
                "User-not-found login completed in \(elapsed)s; bcrypt verify likely skipped (cost 12 is ≥100 ms).")

        }
    }

    // MARK: - Access control

    @Test func unauthenticatedHomeRedirectsToLogin() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(
                .GET, "/",
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/login")
                })

        }
    }

    @Test func studentCannotAccessTestSetupNew() async throws {
        try await withApp(try await makeApp()) { app in
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
                    #expect(res.status == .forbidden)
                })

        }
    }

    @Test func studentCannotAccessAdminPage() async throws {
        try await withApp(try await makeApp()) { app in
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
                    #expect(res.status == .forbidden)
                })

        }
    }

    @Test func studentCannotAccessAssignmentsPage() async throws {
        try await withApp(try await makeApp()) { app in
            let hash = try Bcrypt.hash("pass1234")
            let student = APIUser(username: "student2", passwordHash: hash, role: "student")
            try await student.save(on: app.db)

            let sessionCookie = try await loginUser(
                username: "student2", password: "pass1234", role: "student", on: app)

            try await app.asyncTest(
                .GET, "/instructor",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })

        }
    }
}
