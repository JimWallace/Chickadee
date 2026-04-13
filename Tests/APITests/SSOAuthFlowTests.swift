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
import Fluent
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
            case succeedImmediatelyWithRefreshToken(idToken: String, refreshToken: String)
            case succeedWithoutVerifier(idToken: String)
        }

        let mode: Mode
        private(set) var requestBodies: [String] = []
        private(set) var revocationBodies: [String] = []

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
            case .succeedImmediatelyWithRefreshToken(let idToken, let refreshToken):
                return (.ok, """
                {"access_token":"access-token","refresh_token":"\(refreshToken)","id_token":"\(idToken)","token_type":"Bearer","expires_in":300}
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

        func recordRevocation(body: String) {
            revocationBodies.append(body)
        }

        func recordedBodies() -> [String] {
            requestBodies
        }

        func recordedRevocations() -> [String] {
            revocationBodies
        }
    }

    // MARK: - App factory

    private func makeApp(
        authMode: AuthMode = .sso,
        oidcConfig: OIDCConfiguration? = nil
    ) async throws -> Application {
        let app = try await Application.make(.testing)
        app.authMode = authMode

        app.sessions.use(.memory)
        app.middleware.use(app.sessions.middleware)
        app.middleware.use(UserSessionAuthenticator())
        configureLeaf(app)

        try await configureTestDatabase(app)

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
        email: String? = "jdoe@example.com",
        extraClaims: [String: String] = [:]
    ) async throws -> String {
        let claims = OIDCIDTokenClaims(
            sub: .init(value: subject),
            iss: .init(value: issuer),
            aud: .init(value: audience),
            exp: .init(value: Date().addingTimeInterval(300)),
            iat: .init(value: Date()),
            name: name,
            preferredName: "Jane",
            givenName: "Jane",
            familyName: "Doe",
            preferredUsername: username,
            email: email,
            extraClaims: extraClaims
        )

        return try await JWTKeyCollection()
            .add(hmac: "test-secret", digestAlgorithm: .sha256)
            .sign(claims)
    }

    private func makeMockOIDCProvider(mode: MockTokenEndpoint.Mode) async throws -> (app: Application, port: Int, endpoint: MockTokenEndpoint) {
        let tokenEndpoint = MockTokenEndpoint(mode: mode)

        let app = try await Application.make(Environment(name: "testing", arguments: ["test"]))
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

        app.post("revoke") { req async throws -> HTTPStatus in
            var body = req.body.data ?? ByteBuffer()
            let bodyString = body.readString(length: body.readableBytes) ?? ""
            await tokenEndpoint.recordRevocation(body: bodyString)
            return .ok
        }

        app.environment.arguments = ["serve"]
        try await app.asyncBoot()
        try await app.startup()
        guard let port = app.http.server.shared.localAddress?.port else {
            throw XCTSkip("mock provider failed to bind a port")
        }
        return (app, port, tokenEndpoint)
    }

    private func startSSOSession(on app: Application, path: String = "/auth/sso/start") async throws -> (cookie: String, state: String) {
        var sessionCookie = ""
        var redirectLocation = ""

        try await app.asyncTest(.GET, path, afterResponse: { res in
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

    private func mergedCookie(existing: String, from response: Response) -> String {
        guard let setCookie = response.headers.first(name: .setCookie), !setCookie.isEmpty else {
            return existing
        }
        return mergedCookie(existing: existing, setCookieHeader: setCookie)
    }

    private func mergedCookie(existing: String, from response: XCTHTTPResponse) -> String {
        guard let setCookie = response.headers.first(name: .setCookie), !setCookie.isEmpty else {
            return existing
        }
        return mergedCookie(existing: existing, setCookieHeader: setCookie)
    }

    private func mergedCookie(existing: String, setCookieHeader: String) -> String {
        if existing.isEmpty { return setCookieHeader }

        func cookiePair(from header: String) -> String {
            header.split(separator: ";", maxSplits: 1).first.map(String.init) ?? header
        }

        let oldPair = cookiePair(from: existing)
        let newPair = cookiePair(from: setCookieHeader)
        let oldName = oldPair.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
        let newName = newPair.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""

        if oldName == newName {
            return newPair
        }
        return oldPair + "; " + newPair
    }

    private func waitForRevocationCount(
        _ expectedCount: Int,
        on endpoint: MockTokenEndpoint,
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async -> [String] {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let revocations = await endpoint.recordedRevocations()
            if revocations.count >= expectedCount {
                return revocations
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await endpoint.recordedRevocations()
    }

    private static let mockOIDCConfig = OIDCConfiguration(
        clientID:     "test-client-id",
        clientSecret: "test-client-secret",
        redirectURI:  "http://localhost:8080/auth/sso/callback",
        discovery: OIDCDiscovery(
            issuer:                "https://duo-test.example.com/oidc/test-client-id",
            authorizationEndpoint: "https://duo-test.example.com/oidc/test-client-id/authorize",
            tokenEndpoint:         "https://duo-test.example.com/oidc/test-client-id/token",
            jwksURI:               "https://duo-test.example.com/oidc/test-client-id/keys",
            revocationEndpoint:    nil,
            endSessionEndpoint:    nil
        ),
        claimConfig: OIDCClaimConfig()
    )

    // MARK: - ssoStart: redirect to IdP

    func testSSOStart_redirectsToAuthorizationEndpoint() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(.GET, "/auth/sso/start", afterResponse: { res in
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
    }

    func testSSOStart_includesRedirectURI() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(.GET, "/auth/sso/start", afterResponse: { res in
                let location = res.headers.first(name: .location) ?? ""
                XCTAssertTrue(location.contains("redirect_uri="))
            })
        }
    }

    // MARK: - ssoCallback: error paths

    func testSSOCallback_missingStateFails() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(.GET, "/auth/sso/callback?code=abc&state=wrong", afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertTrue(
                    res.headers.first(name: .location)?.contains("sso_failed") == true,
                    "Expected sso_failed redirect"
                )
            })
        }
    }

    func testSSOCallback_missingCodeFails() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(.GET, "/auth/sso/callback?state=somestate", afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertTrue(
                    res.headers.first(name: .location)?.contains("sso_failed") == true
                )
            })
        }
    }

    func testSSOCallback_idpErrorRedirectsToDenied() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(
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
    }

    // MARK: - Local mode: SSO routes absent

    func testLocalMode_ssoStartNotRegistered() async throws {
        try await withApp(try await makeApp(authMode: .local)) { app in
            try await app.asyncTest(.GET, "/auth/sso/start", afterResponse: { res in
                XCTAssertEqual(res.status, .notFound)
            })
        }
    }

    func testSSOCallbackSuccessUsesFallbackTokenRequestAndUpsertsMappedUser() async throws {
        let idToken = try await signedToken(
            issuer: "http://127.0.0.1/issuer",
            audience: ["test-client-id"],
            subject: "subject-fallback"
        )
        let provider = try await makeMockOIDCProvider(mode: .succeedWithoutVerifier(idToken: idToken))

        let config = OIDCConfiguration(
            clientID: "test-client-id",
            clientSecret: "test-client-secret",
            redirectURI: "http://localhost:8080/auth/sso/callback",
            discovery: OIDCDiscovery(
                issuer: "http://127.0.0.1/issuer",
                authorizationEndpoint: "http://127.0.0.1:\(provider.port)/authorize",
                tokenEndpoint: "http://127.0.0.1:\(provider.port)/token",
                jwksURI: "http://127.0.0.1:\(provider.port)/keys",
                revocationEndpoint: nil,
                endSessionEndpoint: nil
            ),
            claimConfig: OIDCClaimConfig()
        )

        try await withApp(provider.app) { _ in
            try await withApp(try await makeApp(oidcConfig: config)) { app in
                await app.jwt.keys.add(hmac: "test-secret", digestAlgorithm: .sha256)
                app.ssoInstructorUsers = ["jdoe"]

                let start = try await startSSOSession(on: app)

                try await app.asyncTest(
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
        }
    }

    func testSSOCallbackRejectsAudienceMismatchAfterTokenExchange() async throws {
        let idToken = try await signedToken(
            issuer: "http://127.0.0.1/issuer",
            audience: ["wrong-client"],
            subject: "subject-bad-aud"
        )
        let provider = try await makeMockOIDCProvider(mode: .succeedImmediately(idToken: idToken))

        let config = OIDCConfiguration(
            clientID: "test-client-id",
            clientSecret: "test-client-secret",
            redirectURI: "http://localhost:8080/auth/sso/callback",
            discovery: OIDCDiscovery(
                issuer: "http://127.0.0.1/issuer",
                authorizationEndpoint: "http://127.0.0.1:\(provider.port)/authorize",
                tokenEndpoint: "http://127.0.0.1:\(provider.port)/token",
                jwksURI: "http://127.0.0.1:\(provider.port)/keys",
                revocationEndpoint: nil,
                endSessionEndpoint: nil
            ),
            claimConfig: OIDCClaimConfig()
        )

        try await withApp(provider.app) { _ in
            try await withApp(try await makeApp(oidcConfig: config)) { app in
                await app.jwt.keys.add(hmac: "test-secret", digestAlgorithm: .sha256)

                let start = try await startSSOSession(on: app)

                try await app.asyncTest(
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
        }
    }

    func testSSOCallbackUsesConfiguredCustomUsernameClaimAndRepairsExistingUsername() async throws {
        let idToken = try await signedToken(
            issuer: "http://127.0.0.1/issuer",
            audience: ["test-client-id"],
            subject: "subject-custom-claim",
            username: nil,
            name: "Jane Doe",
            email: "jane@example.com",
            extraClaims: [
                "winaccountname": "janedoe",
                "student_id": "12345678",
            ]
        )
        let provider = try await makeMockOIDCProvider(mode: .succeedImmediately(idToken: idToken))

        let config = OIDCConfiguration(
            clientID: "test-client-id",
            clientSecret: "test-client-secret",
            redirectURI: "http://localhost:8080/auth/sso/callback",
            discovery: OIDCDiscovery(
                issuer: "http://127.0.0.1/issuer",
                authorizationEndpoint: "http://127.0.0.1:\(provider.port)/authorize",
                tokenEndpoint: "http://127.0.0.1:\(provider.port)/token",
                jwksURI: "http://127.0.0.1:\(provider.port)/keys",
                revocationEndpoint: nil,
                endSessionEndpoint: nil
            ),
            claimConfig: OIDCClaimConfig(usernameClaim: "winaccountname")
        )

        try await withApp(provider.app) { _ in
            try await withApp(try await makeApp(oidcConfig: config)) { app in
                await app.jwt.keys.add(hmac: "test-secret", digestAlgorithm: .sha256)

                let staleUser = APIUser(
                    username: "ff49217e4e656cb2a9a1d7017203ff74dd22b344e8fc3a845a026a58e23e30c6",
                    passwordHash: "",
                    role: "student",
                    authProvider: "duo-oidc",
                    externalSubject: "subject-custom-claim"
                )
                try await staleUser.save(on: app.db)

                let start = try await startSSOSession(on: app)

                try await app.asyncTest(
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
                    .filter(\.$externalSubject == "subject-custom-claim")
                    .first()
                let user = try XCTUnwrap(fetchedUser)
                XCTAssertEqual(user.username, "janedoe")
                XCTAssertEqual(user.userIdentifier, "janedoe")
                XCTAssertEqual(user.studentID, "12345678")
                XCTAssertEqual(user.email, "jane@example.com")
            }
        }
    }

    func testSSOCallbackPreservesExplicitUserIDClaimWhenRepairingUsername() async throws {
        let idToken = try await signedToken(
            issuer: "http://127.0.0.1/issuer",
            audience: ["test-client-id"],
            subject: "subject-user-id-claim",
            username: nil,
            name: "Jane Doe",
            email: "jane@example.com",
            extraClaims: [
                "winaccountname": "janedoe",
                "user_id": "jd12345",
                "student_id": "12345678",
            ]
        )
        let provider = try await makeMockOIDCProvider(mode: .succeedImmediately(idToken: idToken))

        let config = OIDCConfiguration(
            clientID: "test-client-id",
            clientSecret: "test-client-secret",
            redirectURI: "http://localhost:8080/auth/sso/callback",
            discovery: OIDCDiscovery(
                issuer: "http://127.0.0.1/issuer",
                authorizationEndpoint: "http://127.0.0.1:\(provider.port)/authorize",
                tokenEndpoint: "http://127.0.0.1:\(provider.port)/token",
                jwksURI: "http://127.0.0.1:\(provider.port)/keys",
                revocationEndpoint: nil,
                endSessionEndpoint: nil
            ),
            claimConfig: OIDCClaimConfig(usernameClaim: "winaccountname")
        )

        try await withApp(provider.app) { _ in
            try await withApp(try await makeApp(oidcConfig: config)) { app in
                await app.jwt.keys.add(hmac: "test-secret", digestAlgorithm: .sha256)

                let staleUser = APIUser(
                    username: "ff49217e4e656cb2a9a1d7017203ff74dd22b344e8fc3a845a026a58e23e30c6",
                    passwordHash: "",
                    role: "student",
                    authProvider: "duo-oidc",
                    externalSubject: "subject-user-id-claim",
                    userIdentifier: "ff49217e4e656cb2a9a1d7017203ff74dd22b344e8fc3a845a026a58e23e30c6"
                )
                try await staleUser.save(on: app.db)

                let start = try await startSSOSession(on: app)

                try await app.asyncTest(
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
                    .filter(\.$externalSubject == "subject-user-id-claim")
                    .first()
                let user = try XCTUnwrap(fetchedUser)
                XCTAssertEqual(user.username, "janedoe")
                XCTAssertEqual(user.userIdentifier, "jd12345")
                XCTAssertEqual(user.studentID, "12345678")
                XCTAssertEqual(user.email, "jane@example.com")
            }
        }
    }

    func testSSOCallbackCreatesNewUserWithCustomUsernameClaim() async throws {
        let subject = "subject-brand-new-user"
        let idToken = try await signedToken(
            issuer: "http://127.0.0.1/issuer",
            audience: ["test-client-id"],
            subject: subject,
            username: nil,          // no preferred_username in token
            name: "Jane Doe",
            email: "jane@example.com",
            extraClaims: ["winaccountname": "janedoe"]
        )
        let provider = try await makeMockOIDCProvider(mode: .succeedImmediately(idToken: idToken))

        let config = OIDCConfiguration(
            clientID: "test-client-id",
            clientSecret: "test-client-secret",
            redirectURI: "http://localhost:8080/auth/sso/callback",
            discovery: OIDCDiscovery(
                issuer: "http://127.0.0.1/issuer",
                authorizationEndpoint: "http://127.0.0.1:\(provider.port)/authorize",
                tokenEndpoint: "http://127.0.0.1:\(provider.port)/token",
                jwksURI: "http://127.0.0.1:\(provider.port)/keys",
                revocationEndpoint: nil,
                endSessionEndpoint: nil
            ),
            claimConfig: OIDCClaimConfig(usernameClaim: "winaccountname")
        )

        try await withApp(provider.app) { _ in
            try await withApp(try await makeApp(oidcConfig: config)) { app in
                await app.jwt.keys.add(hmac: "test-secret", digestAlgorithm: .sha256)

                // Confirm no pre-existing record — this is a first-ever login
                let existingCount = try await APIUser.query(on: app.db)
                    .filter(\.$externalSubject == subject)
                    .count()
                XCTAssertEqual(existingCount, 0)

                let start = try await startSSOSession(on: app)

                try await app.asyncTest(
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
                    .filter(\.$externalSubject == subject)
                    .first()
                let user = try XCTUnwrap(fetchedUser)
                XCTAssertEqual(
                    user.username, "janedoe",
                    "New SSO user must get username from winaccountname claim, not the sub hash"
                )
                XCTAssertEqual(user.userIdentifier, "janedoe")
                XCTAssertEqual(user.email, "jane@example.com")
                XCTAssertEqual(user.authProvider, "duo-oidc")
            }
        }
    }

    func testLogoutRevokesAccessAndRefreshTokensAndRedirectsToEndSession() async throws {
        let idToken = try await signedToken(
            issuer: "http://127.0.0.1/issuer",
            audience: ["test-client-id"],
            subject: "subject-logout"
        )
        let provider = try await makeMockOIDCProvider(
            mode: .succeedImmediatelyWithRefreshToken(
                idToken: idToken,
                refreshToken: "refresh-token"
            )
        )

        let config = OIDCConfiguration(
            clientID: "test-client-id",
            clientSecret: "test-client-secret",
            redirectURI: "http://localhost:8080/auth/sso/callback",
            discovery: OIDCDiscovery(
                issuer: "http://127.0.0.1/issuer",
                authorizationEndpoint: "http://127.0.0.1:\(provider.port)/authorize",
                tokenEndpoint: "http://127.0.0.1:\(provider.port)/token",
                jwksURI: "http://127.0.0.1:\(provider.port)/keys",
                revocationEndpoint: "http://127.0.0.1:\(provider.port)/revoke",
                endSessionEndpoint: "http://127.0.0.1:\(provider.port)/logout"
            ),
            claimConfig: OIDCClaimConfig()
        )

        try await withApp(provider.app) { _ in
            try await withApp(try await makeApp(oidcConfig: config)) { app in
                await app.jwt.keys.add(hmac: "test-secret", digestAlgorithm: .sha256)

                let start = try await startSSOSession(on: app)
                var authCookie = start.cookie

                try await app.asyncTest(
                    .GET,
                    "/auth/sso/callback?code=code123&state=\(start.state)",
                    beforeRequest: { req in
                        req.headers.add(name: .cookie, value: start.cookie)
                    },
                    afterResponse: { res in
                        XCTAssertEqual(res.status, .seeOther)
                        XCTAssertEqual(res.headers.first(name: .location), "/")
                        authCookie = mergedCookie(existing: start.cookie, from: res)
                    }
                )

                let (csrf, boundCookie) = try await csrfFields(for: "/account", cookie: authCookie, on: app)
                authCookie = boundCookie

                try await app.asyncTest(
                    .POST,
                    "/logout",
                    beforeRequest: { req in
                        req.headers.add(name: .cookie, value: authCookie)
                        try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                    },
                    afterResponse: { res in
                        XCTAssertEqual(res.status, .seeOther)
                        let redirect = res.headers.first(name: .location) ?? ""
                        XCTAssertTrue(redirect.hasPrefix("http://127.0.0.1:\(provider.port)/logout"))
                        XCTAssertTrue(redirect.contains("id_token_hint="))
                    }
                )

                let revocations = await waitForRevocationCount(2, on: provider.endpoint)
                XCTAssertEqual(revocations.count, 2)
                XCTAssertTrue(revocations.contains(where: {
                    $0.contains("token=access-token") && $0.contains("token_type_hint=access_token")
                }))
                XCTAssertTrue(revocations.contains(where: {
                    $0.contains("token=refresh-token") && $0.contains("token_type_hint=refresh_token")
                }))
            }
        }
    }

    func testSSOCallbackClearsSessionStateAfterFailedAttempt() async throws {
        try await withApp(try await makeApp()) { app in
            let start = try await startSSOSession(on: app)

            try await app.asyncTest(
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

            try await app.asyncTest(
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
    }

    func testCustomOIDCCallbackRouteUsesConfiguredPath() async throws {
        try await withEnvironment(["OIDC_CALLBACK": "oidc/custom/callback"]) {
            try await withApp(try await makeApp()) { app in
                try await app.asyncTest(.GET, "/oidc/custom/callback?error=access_denied", afterResponse: { res in
                    XCTAssertEqual(res.status, .seeOther)
                    XCTAssertTrue(res.headers.first(name: .location)?.contains("sso_denied") == true)
                })
            }
        }
    }
}
