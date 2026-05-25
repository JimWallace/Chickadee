// Tests/APITests/SSOAuthFlowTests.swift
//
// Tests for the real OIDC authorization code flow in SSOAuthRoutes.
//
// These tests inject a mock OIDCConfiguration (no network calls) and cover the
// controllable parts of the flow: redirect generation, PKCE/state storage, and
// callback error paths. End-to-end token exchange requires real IdP credentials
// and is out of scope for unit tests.

import Fluent
import Foundation
import JWT
import Testing
import XCTVapor

@testable import APIServer

@Suite struct SSOAuthFlowTests {

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
                return (
                    .ok,
                    """
                    {"access_token":"access-token","id_token":"\(idToken)","token_type":"Bearer","expires_in":300}
                    """
                )
            case .succeedImmediatelyWithRefreshToken(let idToken, let refreshToken):
                return (
                    .ok,
                    """
                    {"access_token":"access-token","refresh_token":"\(refreshToken)","id_token":"\(idToken)","token_type":"Bearer","expires_in":300}
                    """
                )
            case .succeedWithoutVerifier(let idToken):
                if body.contains("code_verifier=") {
                    return (.badRequest, #"{"error":"pkce_not_supported"}"#)
                }
                return (
                    .ok,
                    """
                    {"access_token":"access-token","id_token":"\(idToken)","token_type":"Bearer","expires_in":300}
                    """
                )
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
        try await makeTestingApplication { app in
            app.authMode = authMode

            app.sessions.use(.memory)
            app.middleware.use(app.sessions.middleware)
            app.middleware.use(UserSessionAuthenticator())
            configureLeaf(app)

            try await configureTestDatabase(app)

            // Inject mock OIDC config — no network calls needed
            app.oidcConfig = oidcConfig ?? Self.mockOIDCConfig

            try routes(app)
        }
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

    private func makeMockOIDCProvider(
        mode: MockTokenEndpoint.Mode
    ) async throws -> (app: Application, port: Int, endpoint: MockTokenEndpoint) {
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

    private func startSSOSession(
        on app: Application, path: String = "/auth/sso/start"
    ) async throws -> (cookie: String, state: String) {
        var sessionCookie = ""
        var redirectLocation = ""

        try await app.asyncTest(
            .GET, path,
            afterResponse: { res in
                #expect(res.status == .seeOther)
                sessionCookie = res.headers.first(name: .setCookie) ?? ""
                redirectLocation = res.headers.first(name: .location) ?? ""
            })

        let components = try #require(URLComponents(string: redirectLocation))
        let state = components.queryItems?.first(where: { $0.name == "state" })?.value ?? ""
        #expect(sessionCookie.isEmpty == false)
        #expect(state.isEmpty == false)
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
        clientID: "test-client-id",
        clientSecret: "test-client-secret",
        redirectURI: "http://localhost:8080/auth/sso/callback",
        discovery: OIDCDiscovery(
            issuer: "https://duo-test.example.com/oidc/test-client-id",
            authorizationEndpoint: "https://duo-test.example.com/oidc/test-client-id/authorize",
            tokenEndpoint: "https://duo-test.example.com/oidc/test-client-id/token",
            jwksURI: "https://duo-test.example.com/oidc/test-client-id/keys",
            revocationEndpoint: nil,
            endSessionEndpoint: nil
        ),
        claimConfig: OIDCClaimConfig()
    )

    // MARK: - ssoStart: redirect to IdP

    @Test func sSOStart_redirectsToAuthorizationEndpoint() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(
                .GET, "/auth/sso/start",
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    let location = res.headers.first(name: .location) ?? ""
                    #expect(
                        location.hasPrefix("https://duo-test.example.com"),
                        "Expected redirect to DUO test host, got: \(location)"
                    )
                    #expect(location.contains("client_id=test-client-id"))
                    #expect(location.contains("response_type=code"))
                    #expect(location.contains("code_challenge_method=S256"))
                    #expect(location.contains("scope=openid"))
                })
        }
    }

    @Test func sSOStart_includesRedirectURI() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(
                .GET, "/auth/sso/start",
                afterResponse: { res in
                    let location = res.headers.first(name: .location) ?? ""
                    #expect(location.contains("redirect_uri="))
                })
        }
    }

    @Test func sSOStart_withoutReauthMarker_doesNotForcePrompt() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(
                .GET, "/auth/sso/start",
                afterResponse: { res in
                    let location = res.headers.first(name: .location) ?? ""
                    #expect(!location.contains("prompt=login"))
                })
        }
    }

    @Test func sSOStart_withReauthMarker_forcesPromptLoginAndClearsMarker() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(
                .GET, "/auth/sso/start",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: "\(reauthMarkerCookieName)=1")
                },
                afterResponse: { res in
                    let location = res.headers.first(name: .location) ?? ""
                    #expect(location.contains("prompt=login"))
                    #expect(location.contains("max_age=0"))
                    // The marker is consumed: a Set-Cookie clears it (empty value).
                    let setCookies = res.headers[.setCookie]
                    let cleared = setCookies.contains { $0.contains("\(reauthMarkerCookieName)=;") }
                    #expect(cleared, "expected the re-auth marker to be cleared, got: \(setCookies)")
                })
        }
    }

    // MARK: - Post-logout login page: SSO entry is a navigation link

    @Test func loginPageAfterLogout_rendersSSOLinkNotForm() async throws {
        // v0.4.211 stopped SSO-only mode from auto-redirecting /login into the
        // SSO flow, which surfaced the "Login with UWaterloo" button for the
        // first time. It must be a navigation link, NOT a form submit — the
        // browser enforces the CSP form-action directive across the whole
        // redirect chain, and the IdP authorization endpoint isn't (and can't
        // reliably be) in that allow-list, so a form submit gets blocked.
        // Regression guard for v0.4.212.
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(
                .GET, "/login?loggedout=1",
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(body.contains("href=\"/auth/sso/start\""))
                    #expect(!body.contains("action=\"/auth/sso/start\""))
                })
        }
    }

    // MARK: - ssoCallback: error paths

    @Test func sSOCallback_missingStateFails() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(
                .GET, "/auth/sso/callback?code=abc&state=wrong",
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(
                        res.headers.first(name: .location)?.contains("sso_failed") == true,
                        "Expected sso_failed redirect"
                    )
                })
        }
    }

    @Test func sSOCallback_missingCodeFails() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(
                .GET, "/auth/sso/callback?state=somestate",
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(
                        res.headers.first(name: .location)?.contains("sso_failed") == true
                    )
                })
        }
    }

    @Test func sSOCallback_idpErrorRedirectsToDenied() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(
                .GET,
                "/auth/sso/callback?error=access_denied&error_description=User+denied+consent",
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(
                        res.headers.first(name: .location)?.contains("sso_denied") == true
                    )
                }
            )
        }
    }

    // MARK: - Local mode: SSO routes absent

    @Test func localMode_ssoStartNotRegistered() async throws {
        try await withApp(try await makeApp(authMode: .local)) { app in
            try await app.asyncTest(
                .GET, "/auth/sso/start",
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })
        }
    }

    @Test func sSOCallbackSuccessUsesFallbackTokenRequestAndUpsertsMappedUser() async throws {
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
                        #expect(res.status == .seeOther)
                        #expect(res.headers.first(name: .location) == "/")
                    }
                )

                let fetchedUser = try await APIUser.query(on: app.db)
                    .filter(\.$externalSubject == "subject-fallback")
                    .first()
                let user = try #require(fetchedUser)
                #expect(user.authProvider == "duo-oidc")
                #expect(user.username == "jdoe")
                #expect(user.role == "instructor")

                let recordedBodies = await provider.endpoint.recordedBodies()
                #expect(recordedBodies.count == 3)
                #expect(recordedBodies[0].contains("code_verifier="))
                #expect(recordedBodies[1].contains("code_verifier="))
                #expect(recordedBodies[2].contains("code_verifier=") == false)
            }
        }
    }

    @Test func sSOCallbackRejectsAudienceMismatchAfterTokenExchange() async throws {
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
                        #expect(res.status == .seeOther)
                        #expect(res.headers.first(name: .location)?.contains("sso_failed") == true)
                    }
                )

                let userCount = try await APIUser.query(on: app.db)
                    .filter(\.$externalSubject == "subject-bad-aud")
                    .count()
                #expect(userCount == 0)
            }
        }
    }

    @Test func sSOCallbackUsesConfiguredCustomUsernameClaimAndRepairsExistingUsername() async throws {
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
                        #expect(res.status == .seeOther)
                        #expect(res.headers.first(name: .location) == "/")
                    }
                )

                let fetchedUser = try await APIUser.query(on: app.db)
                    .filter(\.$externalSubject == "subject-custom-claim")
                    .first()
                let user = try #require(fetchedUser)
                #expect(user.username == "janedoe")
                #expect(user.userIdentifier == "janedoe")
                #expect(user.studentID == "12345678")
                #expect(user.email == "jane@example.com")
            }
        }
    }

    @Test func sSOCallbackPreservesExplicitUserIDClaimWhenRepairingUsername() async throws {
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
                        #expect(res.status == .seeOther)
                        #expect(res.headers.first(name: .location) == "/")
                    }
                )

                let fetchedUser = try await APIUser.query(on: app.db)
                    .filter(\.$externalSubject == "subject-user-id-claim")
                    .first()
                let user = try #require(fetchedUser)
                #expect(user.username == "janedoe")
                #expect(user.userIdentifier == "jd12345")
                #expect(user.studentID == "12345678")
                #expect(user.email == "jane@example.com")
            }
        }
    }

    @Test func sSOCallbackCreatesNewUserWithCustomUsernameClaim() async throws {
        let subject = "subject-brand-new-user"
        let idToken = try await signedToken(
            issuer: "http://127.0.0.1/issuer",
            audience: ["test-client-id"],
            subject: subject,
            username: nil,  // no preferred_username in token
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
                #expect(existingCount == 0)

                let start = try await startSSOSession(on: app)

                try await app.asyncTest(
                    .GET,
                    "/auth/sso/callback?code=code123&state=\(start.state)",
                    beforeRequest: { req in
                        req.headers.add(name: .cookie, value: start.cookie)
                    },
                    afterResponse: { res in
                        #expect(res.status == .seeOther)
                        #expect(res.headers.first(name: .location) == "/")
                    }
                )

                let fetchedUser = try await APIUser.query(on: app.db)
                    .filter(\.$externalSubject == subject)
                    .first()
                let user = try #require(fetchedUser)
                #expect(
                    user.username == "janedoe",
                    "New SSO user must get username from winaccountname claim, not the sub hash")
                #expect(user.userIdentifier == "janedoe")
                #expect(user.email == "jane@example.com")
                #expect(user.authProvider == "duo-oidc")
            }
        }
    }

    @Test func logoutRevokesAccessAndRefreshTokensAndRedirectsToEndSession() async throws {
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
                        #expect(res.status == .seeOther)
                        #expect(res.headers.first(name: .location) == "/")
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
                        #expect(res.status == .seeOther)
                        let redirect = res.headers.first(name: .location) ?? ""
                        #expect(redirect.hasPrefix("http://127.0.0.1:\(provider.port)/logout"))
                        #expect(redirect.contains("id_token_hint="))
                    }
                )

                let revocations = await waitForRevocationCount(2, on: provider.endpoint)
                #expect(revocations.count == 2)
                #expect(
                    revocations.contains(where: {
                        $0.contains("token=access-token") && $0.contains("token_type_hint=access_token")
                    }))
                #expect(
                    revocations.contains(where: {
                        $0.contains("token=refresh-token") && $0.contains("token_type_hint=refresh_token")
                    }))
            }
        }
    }

    @Test func sSOCallbackClearsSessionStateAfterFailedAttempt() async throws {
        try await withApp(try await makeApp()) { app in
            let start = try await startSSOSession(on: app)

            try await app.asyncTest(
                .GET,
                "/auth/sso/callback?code=first&state=wrong-state",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: start.cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location)?.contains("sso_failed") == true)
                }
            )

            try await app.asyncTest(
                .GET,
                "/auth/sso/callback?code=second&state=\(start.state)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: start.cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location)?.contains("sso_failed") == true)
                }
            )
        }
    }

    @Test func customOIDCCallbackRouteUsesConfiguredPath() async throws {
        try await withEnvironment(["OIDC_CALLBACK": "oidc/custom/callback"]) {
            try await withApp(try await makeApp()) { app in
                try await app.asyncTest(
                    .GET, "/oidc/custom/callback?error=access_denied",
                    afterResponse: { res in
                        #expect(res.status == .seeOther)
                        #expect(res.headers.first(name: .location)?.contains("sso_denied") == true)
                    })
            }
        }
    }
}
