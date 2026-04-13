// Tests/APITests/AuthModeGatingTests.swift
//
// Verify that SSO routes are gated by authMode:
//   - .local → /auth/sso/start and /auth/sso/callback return 404 (not registered)
//   - .sso   → both routes return 303 redirect (registered; no oidcConfig → error redirect)
//   - .dual  → same as .sso; local login routes still present

import XCTest
import XCTVapor
@testable import chickadee_server
import Fluent

final class AuthModeGatingTests: XCTestCase {

    private func makeApp(authMode: AuthMode) async throws -> Application {
        let app = try await Application.make(.testing)
        app.authMode = authMode

        app.sessions.use(.memory)
        app.middleware.use(app.sessions.middleware)

        try await configureTestDatabase(app)

        try routes(app)
        return app
    }

    // MARK: - Local mode: SSO routes absent

    func testLocalMode_ssoStartReturns404() async throws {
        try await withApp(try await makeApp(authMode: .local)) { app in
            try await app.asyncTest(.GET, "/auth/sso/start", afterResponse: { res in
                XCTAssertEqual(res.status, .notFound)
            })
        }
    }

    func testLocalMode_ssoCallbackReturns404() async throws {
        try await withApp(try await makeApp(authMode: .local)) { app in
            try await app.asyncTest(.GET, "/auth/sso/callback", afterResponse: { res in
                XCTAssertEqual(res.status, .notFound)
            })
        }
    }

    // MARK: - SSO mode: routes present (redirect to error page when oidcConfig not loaded)

    func testSSOMode_ssoStartRedirectsWhenNotConfigured() async throws {
        try await withApp(try await makeApp(authMode: .sso)) { app in
            try await app.asyncTest(.GET, "/auth/sso/start", afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertTrue(
                    res.headers.first(name: .location)?.contains("sso_not_configured") == true
                )
            })
        }
    }

    func testSSOMode_ssoCallbackRedirectsWhenNotConfigured() async throws {
        try await withApp(try await makeApp(authMode: .sso)) { app in
            try await app.asyncTest(.GET, "/auth/sso/callback", afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertTrue(
                    res.headers.first(name: .location)?.contains("sso_not_configured") == true
                )
            })
        }
    }

    func testSSOMode_localLoginPostNotRegistered() async throws {
        try await withApp(try await makeApp(authMode: .sso)) { app in
            try await app.asyncTest(.POST, "/login", afterResponse: { res in
                XCTAssertTrue(
                    res.status == .forbidden || res.status == .notFound,
                    "POST /login must be inaccessible in SSO mode, got \(res.status)")
            })
        }
    }

    func testSSOMode_registerNotRegistered() async throws {
        try await withApp(try await makeApp(authMode: .sso)) { app in
            try await app.asyncTest(.GET, "/register", afterResponse: { res in
                XCTAssertEqual(res.status, .notFound)
            })
        }
    }

    func testSSOMode_loginAutoRedirectsToSSOStart() async throws {
        try await withApp(try await makeApp(authMode: .sso)) { app in
            try await app.asyncTest(.GET, "/login", afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertEqual(res.headers.first(name: .location), "/auth/sso/start")
            })
        }
    }

    func testSSOMode_customCallbackRouteRegisteredFromEnv() async throws {
        setenv("OIDC_CALLBACK", "/oidc/duo/callback/", 1)
        defer { unsetenv("OIDC_CALLBACK") }

        try await withApp(try await makeApp(authMode: .sso)) { app in
            try await app.asyncTest(.GET, "/oidc/duo/callback", afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertTrue(
                    res.headers.first(name: .location)?.contains("sso_not_configured") == true
                )
            })
        }
    }

    // MARK: - Dual mode: SSO routes present alongside local login

    func testDualMode_ssoStartRedirectsWhenNotConfigured() async throws {
        try await withApp(try await makeApp(authMode: .dual)) { app in
            try await app.asyncTest(.GET, "/auth/sso/start", afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertNotEqual(res.status, .notFound)
            })
        }
    }

    func testDualMode_localLoginStillWorks() async throws {
        try await withApp(try await makeApp(authMode: .dual)) { app in
            try await app.asyncTest(.GET, "/login", afterResponse: { res in
                XCTAssertNotEqual(res.status, .notFound)
            })
        }
    }

    func testDualMode_localLoginPostStillRegistered() async throws {
        try await withApp(try await makeApp(authMode: .dual)) { app in
            try await app.asyncTest(.POST, "/login", afterResponse: { res in
                XCTAssertNotEqual(res.status, .notFound)
            })
        }
    }
}
