// Tests/APITests/AuthModeGatingTests.swift
//
// Verify that SSO routes are gated by authMode:
//   - .local → /auth/sso/start and /auth/sso/callback return 404 (not registered)
//   - .sso   → both routes return 501 (stub registered, provider not yet wired)
//   - .dual  → same as .sso

import XCTest
import XCTVapor
@testable import chickadee_server
import FluentSQLiteDriver

final class AuthModeGatingTests: XCTestCase {

    private func makeApp(authMode: AuthMode) throws -> Application {
        let app = Application(.testing)
        app.authMode = authMode

        app.sessions.use(.memory)
        app.middleware.use(app.sessions.middleware)

        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateTestSetups())
        app.migrations.add(CreateSubmissions())
        app.migrations.add(CreateResults())
        app.migrations.add(CreateUsers())
        app.migrations.add(AddUserSSOFields())
        app.migrations.add(CreateAssignments())
        app.migrations.add(CreatePerformanceIndexes())
        try app.autoMigrate().wait()

        try routes(app)
        return app
    }

    // MARK: - Local mode: SSO routes absent

    func testLocalMode_ssoStartReturns404() async throws {
        let app = try makeApp(authMode: .local)
        defer { app.shutdown() }

        try await app.test(.GET, "/auth/sso/start", afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    func testLocalMode_ssoCallbackReturns404() async throws {
        let app = try makeApp(authMode: .local)
        defer { app.shutdown() }

        try await app.test(.GET, "/auth/sso/callback", afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    // MARK: - SSO mode: routes present (501 until provider is wired)

    func testSSOMode_ssoStartReturns501() async throws {
        let app = try makeApp(authMode: .sso)
        defer { app.shutdown() }

        try await app.test(.GET, "/auth/sso/start", afterResponse: { res in
            XCTAssertEqual(res.status, .notImplemented)
        })
    }

    func testSSOMode_ssoCallbackReturns501() async throws {
        let app = try makeApp(authMode: .sso)
        defer { app.shutdown() }

        try await app.test(.GET, "/auth/sso/callback", afterResponse: { res in
            XCTAssertEqual(res.status, .notImplemented)
        })
    }

    // MARK: - Dual mode: SSO routes present alongside local login

    func testDualMode_ssoStartReturns501() async throws {
        let app = try makeApp(authMode: .dual)
        defer { app.shutdown() }

        try await app.test(.GET, "/auth/sso/start", afterResponse: { res in
            XCTAssertEqual(res.status, .notImplemented)
        })
    }

    func testDualMode_localLoginStillWorks() async throws {
        let app = try makeApp(authMode: .dual)
        defer { app.shutdown() }

        // GET /login should still exist in dual mode.
        try await app.test(.GET, "/login", afterResponse: { res in
            // 500 expected (Leaf not configured in tests) but not 404.
            XCTAssertNotEqual(res.status, .notFound)
        })
    }
}
