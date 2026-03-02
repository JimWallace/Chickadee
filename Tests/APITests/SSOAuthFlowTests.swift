// Tests/APITests/SSOAuthFlowTests.swift
//
// Tests for the real OIDC authorization code flow in SSOAuthRoutes.
//
// These tests inject a mock OIDCConfiguration (no network calls) and cover the
// controllable parts of the flow: redirect generation, PKCE/state storage, and
// callback error paths. End-to-end token exchange requires real IdP credentials
// and is out of scope for unit tests.

import XCTest
import XCTVapor
@testable import chickadee_server
import FluentSQLiteDriver

final class SSOAuthFlowTests: XCTestCase {

    // MARK: - App factory

    private func makeApp(authMode: AuthMode = .sso) throws -> Application {
        let app = Application(.testing)
        app.authMode = authMode

        app.sessions.use(.memory)
        app.middleware.use(app.sessions.middleware)
        app.middleware.use(UserSessionAuthenticator())

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

        // Inject mock OIDC config — no network calls needed
        app.oidcConfig = Self.mockOIDCConfig

        try routes(app)
        return app
    }

    private static let mockOIDCConfig = OIDCConfiguration(
        clientID:     "test-client-id",
        clientSecret: "test-client-secret",
        redirectURI:  "http://localhost:8080/auth/sso/callback",
        discovery: OIDCDiscovery(
            issuer:                "https://duo-test.example.com/oidc/test-client-id",
            authorizationEndpoint: "https://duo-test.example.com/oidc/test-client-id/authorize",
            tokenEndpoint:         "https://duo-test.example.com/oidc/test-client-id/token",
            jwksURI:               "https://duo-test.example.com/oidc/test-client-id/keys"
        )
    )

    // MARK: - ssoStart: redirect to IdP

    func testSSOStart_redirectsToAuthorizationEndpoint() async throws {
        let app = try makeApp()
        defer { app.shutdown() }

        try await app.test(.GET, "/auth/sso/start", afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            let location = res.headers.first(name: .location) ?? ""
            XCTAssertTrue(
                location.hasPrefix("https://duo-test.example.com"),
                "Expected redirect to DUO test host, got: \(location)"
            )
            XCTAssertTrue(location.contains("client_id=test-client-id"))
            XCTAssertTrue(location.contains("response_type=code"))
            XCTAssertTrue(location.contains("code_challenge_method=S256"))
            XCTAssertTrue(location.contains("scope=openid"))
        })
    }

    func testSSOStart_includesRedirectURI() async throws {
        let app = try makeApp()
        defer { app.shutdown() }

        try await app.test(.GET, "/auth/sso/start", afterResponse: { res in
            let location = res.headers.first(name: .location) ?? ""
            // redirect_uri must be percent-encoded in the query string
            XCTAssertTrue(location.contains("redirect_uri="))
        })
    }

    // MARK: - ssoCallback: error paths

    func testSSOCallback_missingStateFails() async throws {
        let app = try makeApp()
        defer { app.shutdown() }

        // No prior ssoStart → empty session → state mismatch
        try await app.test(.GET, "/auth/sso/callback?code=abc&state=wrong", afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertTrue(
                res.headers.first(name: .location)?.contains("sso_failed") == true,
                "Expected sso_failed redirect"
            )
        })
    }

    func testSSOCallback_missingCodeFails() async throws {
        let app = try makeApp()
        defer { app.shutdown() }

        // state present in query but no code (also no matching session state)
        try await app.test(.GET, "/auth/sso/callback?state=somestate", afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertTrue(
                res.headers.first(name: .location)?.contains("sso_failed") == true
            )
        })
    }

    func testSSOCallback_idpErrorRedirectsToDenied() async throws {
        let app = try makeApp()
        defer { app.shutdown() }

        // IdP signals that user denied consent
        try await app.test(
            .GET,
            "/auth/sso/callback?error=access_denied&error_description=User+denied+consent",
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertTrue(
                    res.headers.first(name: .location)?.contains("sso_denied") == true
                )
            }
        )
    }

    // MARK: - Local mode: SSO routes absent

    func testLocalMode_ssoStartNotRegistered() async throws {
        let app = try makeApp(authMode: .local)
        defer { app.shutdown() }

        try await app.test(.GET, "/auth/sso/start", afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
    }
}
