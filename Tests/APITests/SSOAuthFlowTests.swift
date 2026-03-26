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
import JWT
import Foundation

final class SSOAuthFlowTests: XCTestCase {

    private struct EnvironmentOverride {
        let key: String
        let previousValue: String?

        init(key: String, value: String?) {
            self.key = key
            self.previousValue = Environment.get(key)
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }

        func restore() {
            if let previousValue {
                setenv(key, previousValue, 1)
            } else {
                unsetenv(key)
            }
        }
    }

    private actor MockTokenEndpoint {
        enum Mode {
            case alwaysFail
            case succeedImmediately(idToken: String)
            case succeedWithoutVerifier(idToken: String)
        }

        let mode: Mode
        private(set) var requestBodies: [String] = []

        init(mode: Mode) {
            self.mode = mode
        }

        func record(body: String) -> (status: HTTPResponseStatus, body: String) {
            requestBodies.append(body)

            switch mode {
            case .alwaysFail:
                return (.badRequest, #"{"error":"invalid_grant"}"#)
            case .succeedImmediately(let idToken):
                return (.ok, """
                {"access_token":"access-token","id_token":"\(idToken)","token_type":"Bearer","expires_in":300}
                """)
            case .succeedWithoutVerifier(let idToken):
                if body.contains("code_verifier=") {
                    return (.badRequest, #"{"error":"pkce_not_supported"}"#)
                }
                return (.ok, """
                {"access_token":"access-token","id_token":"\(idToken)","token_type":"Bearer","expires_in":300}
                """)
            }
        }

        func recordedBodies() -> [String] {
            requestBodies
        }
    }

    // MARK: - App factory

    private func makeApp(
        authMode: AuthMode = .sso,
        oidcConfig: OIDCConfiguration? = nil
    ) throws -> Application {
        let app = Application(.testing)
        app.authMode = authMode

        app.sessions.use(.memory)
        app.middleware.use(app.sessions.middleware)
        app.middleware.use(UserSessionAuthenticator())

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
        try app.autoMigrate().wait()

        // Inject mock OIDC config — no network calls needed
        app.oidcConfig = oidcConfig ?? Self.mockOIDCConfig

        try routes(app)
        return app
    }

    private func withEnvironment(
        _ values: [String: String?],
        perform operation: () async throws -> Void
    ) async rethrows {
        let overrides = values.map { EnvironmentOverride(key: $0.key, value: $0.value) }
        defer {
            for override in overrides.reversed() {
                override.restore()
            }
        }
        try await operation()
    }

    private func signedToken(
        issuer: String,
        audience: [String],
        subject: String = "subject-123",
        username: String? = "jdoe",
        name: String? = "Jane Doe",
        email: String? = "jdoe@example.com"
    ) async throws -> String {
        let claims = OIDCIDTokenClaims(
            sub: .init(value: subject),
            iss: .init(value: issuer),
            aud: .init(value: audience),
            exp: .init(value: Date().addingTimeInterval(300)),
            iat: .init(value: Date()),
            winaccountname: username,
            name: name,
            preferredName: "Jane",
            givenName: "Jane",
            familyName: "Doe",
            userID: "uwaterloo-\(subject)",
            studentID: "12345678",
            email: email
        )

        return try await JWTKeyCollection()
            .add(hmac: "test-secret", digestAlgorithm: .sha256)
            .sign(claims)
    }

    private func makeMockOIDCProvider(mode: MockTokenEndpoint.Mode) async throws -> (app: Application, port: Int, endpoint: MockTokenEndpoint) {
        let tokenEndpoint = MockTokenEndpoint(mode: mode)

        let app = Application(Environment(name: "testing", arguments: ["test"]))
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0

        app.post("token") { req async throws -> Response in
            var body = req.body.data ?? ByteBuffer()
            let bodyString = body.readString(length: body.readableBytes) ?? ""
            let result = await tokenEndpoint.record(body: bodyString)
            let response = Response(status: result.status, body: .init(string: result.body))
            response.headers.contentType = .json
            return response
        }

        try app.start()
        guard let port = app.http.server.shared.localAddress?.port else {
            throw XCTSkip("mock provider failed to bind a port")
        }
        return (app, port, tokenEndpoint)
    }

    private func startSSOSession(on app: Application, path: String = "/auth/sso/start") async throws -> (cookie: String, state: String) {
        var sessionCookie = ""
        var redirectLocation = ""

        try await app.test(.GET, path, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            sessionCookie = res.headers.first(name: .setCookie) ?? ""
            redirectLocation = res.headers.first(name: .location) ?? ""
        })

        let components = try XCTUnwrap(URLComponents(string: redirectLocation))
        let state = components.queryItems?.first(where: { $0.name == "state" })?.value ?? ""
        XCTAssertFalse(sessionCookie.isEmpty)
        XCTAssertFalse(state.isEmpty)
        return (sessionCookie, state)
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

    func testSSOCallbackSuccessUsesFallbackTokenRequestAndUpsertsMappedUser() async throws {
        let idToken = try await signedToken(
            issuer: "http://127.0.0.1/issuer",
            audience: ["test-client-id"],
            subject: "subject-fallback"
        )
        let provider = try await makeMockOIDCProvider(mode: .succeedWithoutVerifier(idToken: idToken))
        defer { provider.app.shutdown() }

        let config = OIDCConfiguration(
            clientID: "test-client-id",
            clientSecret: "test-client-secret",
            redirectURI: "http://localhost:8080/auth/sso/callback",
            discovery: OIDCDiscovery(
                issuer: "http://127.0.0.1/issuer",
                authorizationEndpoint: "http://127.0.0.1:\(provider.port)/authorize",
                tokenEndpoint: "http://127.0.0.1:\(provider.port)/token",
                jwksURI: "http://127.0.0.1:\(provider.port)/keys"
            )
        )

        let app = try makeApp(oidcConfig: config)
        defer { app.shutdown() }
        await app.jwt.keys.add(hmac: "test-secret", digestAlgorithm: .sha256)
        app.ssoInstructorUsers = ["jdoe"]

        let start = try await startSSOSession(on: app)

        try await app.test(
            .GET,
            "/auth/sso/callback?code=code123&state=\(start.state)",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: start.cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertEqual(res.headers.first(name: .location), "/")
            }
        )

        let fetchedUser = try await APIUser.query(on: app.db)
            .filter(\.$externalSubject == "subject-fallback")
            .first()
        let user = try XCTUnwrap(fetchedUser)
        XCTAssertEqual(user.authProvider, "duo-oidc")
        XCTAssertEqual(user.username, "jdoe")
        XCTAssertEqual(user.role, "instructor")

        let recordedBodies = await provider.endpoint.recordedBodies()
        XCTAssertEqual(recordedBodies.count, 3)
        XCTAssertTrue(recordedBodies[0].contains("code_verifier="))
        XCTAssertTrue(recordedBodies[1].contains("code_verifier="))
        XCTAssertFalse(recordedBodies[2].contains("code_verifier="))
    }

    func testSSOCallbackRejectsAudienceMismatchAfterTokenExchange() async throws {
        let idToken = try await signedToken(
            issuer: "http://127.0.0.1/issuer",
            audience: ["wrong-client"],
            subject: "subject-bad-aud"
        )
        let provider = try await makeMockOIDCProvider(mode: .succeedImmediately(idToken: idToken))
        defer { provider.app.shutdown() }

        let config = OIDCConfiguration(
            clientID: "test-client-id",
            clientSecret: "test-client-secret",
            redirectURI: "http://localhost:8080/auth/sso/callback",
            discovery: OIDCDiscovery(
                issuer: "http://127.0.0.1/issuer",
                authorizationEndpoint: "http://127.0.0.1:\(provider.port)/authorize",
                tokenEndpoint: "http://127.0.0.1:\(provider.port)/token",
                jwksURI: "http://127.0.0.1:\(provider.port)/keys"
            )
        )

        let app = try makeApp(oidcConfig: config)
        defer { app.shutdown() }
        await app.jwt.keys.add(hmac: "test-secret", digestAlgorithm: .sha256)

        let start = try await startSSOSession(on: app)

        try await app.test(
            .GET,
            "/auth/sso/callback?code=code123&state=\(start.state)",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: start.cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertTrue(res.headers.first(name: .location)?.contains("sso_failed") == true)
            }
        )

        let userCount = try await APIUser.query(on: app.db)
            .filter(\.$externalSubject == "subject-bad-aud")
            .count()
        XCTAssertEqual(userCount, 0)
    }

    func testSSOCallbackClearsSessionStateAfterFailedAttempt() async throws {
        let app = try makeApp()
        defer { app.shutdown() }

        let start = try await startSSOSession(on: app)

        try await app.test(
            .GET,
            "/auth/sso/callback?code=first&state=wrong-state",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: start.cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertTrue(res.headers.first(name: .location)?.contains("sso_failed") == true)
            }
        )

        try await app.test(
            .GET,
            "/auth/sso/callback?code=second&state=\(start.state)",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: start.cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertTrue(res.headers.first(name: .location)?.contains("sso_failed") == true)
            }
        )
    }

    func testCustomOIDCCallbackRouteUsesConfiguredPath() async throws {
        try await withEnvironment(["OIDC_CALLBACK": "oidc/custom/callback"]) {
            let app = try makeApp()
            defer { app.shutdown() }

            try await app.test(.GET, "/oidc/custom/callback?error=access_denied", afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertTrue(res.headers.first(name: .location)?.contains("sso_denied") == true)
            })
        }
    }
}
