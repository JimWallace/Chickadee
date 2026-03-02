// Tests/APITests/AuthModeGatingTests.swift
//
// Verify that SSO routes are gated by authMode:
//   - .local → /auth/sso/start and /auth/sso/callback return 404 (not registered)
//   - .sso   → both routes return 303 redirect (registered; no oidcConfig → error redirect)
//   - .dual  → same as .sso; local login routes still present

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
        app.migrations.add(AddUserProfileFields())
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

    // MARK: - SSO mode: routes present (redirect to error page when oidcConfig not loaded)

    func testSSOMode_ssoStartRedirectsWhenNotConfigured() async throws {
        let app = try makeApp(authMode: .sso)
        defer { app.shutdown() }

        // oidcConfig is nil → handler redirects to error page (303, not 404)
        try await app.test(.GET, "/auth/sso/start", afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertTrue(
                res.headers.first(name: .location)?.contains("sso_not_configured") == true
            )
        })
    }

    func testSSOMode_ssoCallbackRedirectsWhenNotConfigured() async throws {
        let app = try makeApp(authMode: .sso)
        defer { app.shutdown() }

        try await app.test(.GET, "/auth/sso/callback", afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertTrue(
                res.headers.first(name: .location)?.contains("sso_not_configured") == true
            )
        })
    }

    func testSSOMode_localLoginPostNotRegistered() async throws {
        let app = try makeApp(authMode: .sso)
        defer { app.shutdown() }

        try await app.test(.POST, "/login", afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    func testSSOMode_registerNotRegistered() async throws {
        let app = try makeApp(authMode: .sso)
        defer { app.shutdown() }

        try await app.test(.GET, "/register", afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    func testSSOMode_customCallbackRouteRegisteredFromEnv() async throws {
        setenv("OIDC_CALLBACK", "/oidc/duo/callback/", 1)
        defer { unsetenv("OIDC_CALLBACK") }

        let app = try makeApp(authMode: .sso)
        defer { app.shutdown() }

        try await app.test(.GET, "/oidc/duo/callback", afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertTrue(
                res.headers.first(name: .location)?.contains("sso_not_configured") == true
            )
        })
    }

    // MARK: - Dual mode: SSO routes present alongside local login

    func testDualMode_ssoStartRedirectsWhenNotConfigured() async throws {
        let app = try makeApp(authMode: .dual)
        defer { app.shutdown() }

        try await app.test(.GET, "/auth/sso/start", afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertNotEqual(res.status, .notFound)
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

    func testDualMode_localLoginPostStillRegistered() async throws {
        let app = try makeApp(authMode: .dual)
        defer { app.shutdown() }

        try await app.test(.POST, "/login", afterResponse: { res in
            XCTAssertNotEqual(res.status, .notFound)
        })
    }
}
