// Tests/APITests/Auth/SSOCallbackRefusalTests.swift
//
// The refusals and fallbacks of the OIDC login routes in SSOAuthRoutes that
// SSOAuthFlowTests does not reach: an authorization URL that cannot be built,
// a callback with a valid state but no code, a token endpoint that refuses
// every request shape or answers with a body that does not decode, an ID token
// that is expired or signed with the wrong key, an ID token from the wrong
// issuer, an SSO username that a local account already holds, and the audit
// entry for a role change that the admin allowlist causes.
//
// The identity provider is a loopback Vapor app on 127.0.0.1. Nothing leaves
// the machine.

import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import JWT
import Testing
import VaporTesting

@testable import APIServer

/// HMAC key the mock identity provider signs its ID tokens with. At least 32
/// bytes, because JWTKit asserts on a shorter HS256 key.
private let refusalTestSigningKey: HMACKey = "chickadee-sso-refusal-signing-key-0123456789"

/// A second key that the app does not trust.
private let untrustedSigningKey: HMACKey = "chickadee-sso-untrusted-signing-key-9876543210"

private let refusalTestIssuer = "http://127.0.0.1/refusal-issuer"
private let refusalTestClientID = "refusal-client-id"

@Suite(.timeLimit(.minutes(2))) struct SSOCallbackRefusalTests {

    /// How the loopback token endpoint answers.
    private enum TokenMode: Sendable {
        /// Every request gets HTTP 400.
        case alwaysFail
        /// HTTP 200 with a body that is not a token response.
        case malformedSuccess
        /// HTTP 400 to a request with an Authorization header (the
        /// client_secret_basic shape); HTTP 200 with the token otherwise.
        case rejectBasicAuth(idToken: String)
        /// HTTP 200 with the token to every request.
        case succeed(idToken: String)
    }

    private actor TokenEndpointLog {
        private(set) var requests: [(authorized: Bool, body: String)] = []

        func record(authorized: Bool, body: String) {
            requests.append((authorized, body))
        }

        func count() -> Int { requests.count }

        func authorizedFlags() -> [Bool] { requests.map(\.authorized) }
    }

    private struct MockProvider {
        let app: Application
        let port: Int
        let log: TokenEndpointLog
    }

    // MARK: - Helpers

    private static func tokenJSON(_ idToken: String) -> String {
        """
        {"access_token":"access-token","id_token":"\(idToken)","token_type":"Bearer","expires_in":300}
        """
    }

    private func makeProvider(mode: TokenMode) async throws -> MockProvider {
        let log = TokenEndpointLog()
        var port = 0
        let app = try await makeTestingApplication(
            environment: Environment(name: "testing", arguments: ["test"])
        ) { app in
            app.http.server.configuration.hostname = "127.0.0.1"
            app.http.server.configuration.port = 0
            app.post("token") { req async throws -> Response in
                var body = req.body.data ?? ByteBuffer()
                let bodyString = body.readString(length: body.readableBytes) ?? ""
                let authorized = req.headers.basicAuthorization != nil
                await log.record(authorized: authorized, body: bodyString)
                let status: HTTPResponseStatus
                let text: String
                switch mode {
                case .alwaysFail:
                    (status, text) = (.badRequest, #"{"error":"invalid_grant"}"#)
                case .malformedSuccess:
                    (status, text) = (.ok, #"{"unexpected":"shape"}"#)
                case .rejectBasicAuth(let idToken):
                    (status, text) =
                        authorized
                        ? (.badRequest, #"{"error":"invalid_client"}"#)
                        : (.ok, Self.tokenJSON(idToken))
                case .succeed(let idToken):
                    (status, text) = (.ok, Self.tokenJSON(idToken))
                }
                let response = Response(status: status, body: .init(string: text))
                response.headers.contentType = .json
                return response
            }
            app.environment.arguments = ["serve"]
            try await app.asyncBoot()
            try await app.startup()
            guard let bound = app.http.server.shared.localAddress?.port else {
                throw IssueRecorded("mock provider failed to bind a port")
            }
            port = bound
        }
        return MockProvider(app: app, port: port, log: log)
    }

    private func config(
        tokenPort: Int,
        authorizationEndpoint: String? = nil
    ) -> OIDCConfiguration {
        OIDCConfiguration(
            clientID: refusalTestClientID,
            clientSecret: "refusal-client-secret",
            redirectURI: "http://localhost:8080/auth/sso/callback",
            discovery: OIDCDiscovery(
                issuer: refusalTestIssuer,
                authorizationEndpoint: authorizationEndpoint ?? "http://127.0.0.1:\(tokenPort)/authorize",
                tokenEndpoint: "http://127.0.0.1:\(tokenPort)/token",
                jwksURI: "http://127.0.0.1:\(tokenPort)/keys",
                revocationEndpoint: nil,
                endSessionEndpoint: nil
            ),
            claimConfig: OIDCClaimConfig()
        )
    }

    private func makeApp(oidcConfig: OIDCConfiguration) async throws -> Application {
        let app = try await makeTestApp(
            authMode: .sso, appConfig: .testDefaults(authMode: .sso, oidc: .default))
        app.middleware.use(UserSessionAuthenticator())
        app.oidcConfig = oidcConfig
        await app.jwt.keys.add(hmac: refusalTestSigningKey, digestAlgorithm: .sha256)
        return app
    }

    private struct TokenSpec {
        var issuer = refusalTestIssuer
        var subject = "refusal-subject"
        var username: String? = "rdoe"
        var name: String? = "Rae Doe"
        var givenName: String? = "Rae"
        var familyName: String? = "Doe"
        var expiresIn: TimeInterval = 300
        var key: HMACKey = refusalTestSigningKey
    }

    private func signedToken(_ spec: TokenSpec) async throws -> String {
        let claims = OIDCIDTokenClaims(
            sub: .init(value: spec.subject),
            iss: .init(value: spec.issuer),
            aud: .init(value: [refusalTestClientID]),
            exp: .init(value: Date().addingTimeInterval(spec.expiresIn)),
            iat: .init(value: Date()),
            name: spec.name,
            preferredName: nil,
            givenName: spec.givenName,
            familyName: spec.familyName,
            preferredUsername: spec.username,
            email: nil,
            extraClaims: [:]
        )
        return try await JWTKeyCollection()
            .add(hmac: spec.key, digestAlgorithm: .sha256)
            .sign(claims)
    }

    /// Starts a login and returns the session cookie and the state it stored.
    private func startLogin(on app: Application) async throws -> (cookie: String, state: String) {
        var cookie = ""
        var location = ""
        try await app.asyncTest(
            .GET, "/auth/sso/start",
            afterResponse: { res in
                #expect(res.status == .seeOther)
                cookie = res.headers.first(name: .setCookie) ?? ""
                location = res.headers.first(name: .location) ?? ""
            })
        let components = try #require(URLComponents(string: location))
        let state = try #require(components.queryItems?.first { $0.name == "state" }?.value)
        #expect(!cookie.isEmpty)
        return (cookie, state)
    }

    /// Runs one callback with the code and the stored state, and returns the
    /// Location header of the redirect.
    private func completeLogin(on app: Application, code: String? = "code123") async throws -> String {
        let start = try await startLogin(on: app)
        let query = code.map { "code=\($0)&state=\(start.state)" } ?? "state=\(start.state)"
        var location = ""
        try await app.asyncTest(
            .GET, "/auth/sso/callback?\(query)",
            beforeRequest: { req in req.headers.add(name: .cookie, value: start.cookie) },
            afterResponse: { res in
                #expect(res.status == .seeOther)
                location = res.headers.first(name: .location) ?? ""
            })
        return location
    }

    /// Runs `body` with a loopback provider in `mode` and an SSO app that
    /// uses it.
    private func withProvider(
        mode: TokenMode,
        _ body: (Application, MockProvider) async throws -> Void
    ) async throws {
        let provider = try await makeProvider(mode: mode)
        try await withApp(provider.app) { _ in
            try await withApp(try await makeApp(oidcConfig: config(tokenPort: provider.port))) { app in
                try await body(app, provider)
            }
        }
    }

    private func userCount(subject: String, on app: Application) async throws -> Int {
        try await APIUser.query(on: app.db).filter(\.$externalSubject == subject).count()
    }

    // MARK: - ssoStart

    @Test func startRefusesWhenTheAuthorizationURLCannotBeBuilt() async throws {
        let broken = config(tokenPort: 9, authorizationEndpoint: "http://[::1")
        try await withApp(try await makeApp(oidcConfig: broken)) { app in
            try await app.asyncTest(
                .GET, "/auth/sso/start",
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/login?error=sso_failed")
                })
        }
    }

    // MARK: - ssoCallback: request refusals

    @Test func callbackWithAValidStateButNoCodeIsRefusedBeforeTheTokenRequest() async throws {
        try await withProvider(mode: .alwaysFail) { app, provider in
            let location = try await completeLogin(on: app, code: nil)
            #expect(location == "/login?error=sso_failed")
            #expect(await provider.log.count() == 0)
        }
    }

    // MARK: - ssoCallback: token exchange

    @Test func callbackIsRefusedWhenEveryTokenRequestShapeFails() async throws {
        try await withProvider(mode: .alwaysFail) { app, provider in
            let location = try await completeLogin(on: app)
            #expect(location == "/login?error=sso_failed")
            #expect(await provider.log.authorizedFlags() == [true, false, false])
            #expect(try await APIUser.query(on: app.db).filter(\.$authProvider == "duo-oidc").count() == 0)
        }
    }

    @Test func callbackIsRefusedWhenTheTokenResponseDoesNotDecode() async throws {
        try await withProvider(mode: .malformedSuccess) { app, provider in
            let location = try await completeLogin(on: app)
            #expect(location == "/login?error=sso_failed")
            // The first answer is HTTP 200, so the exchange stops there and throws.
            #expect(await provider.log.count() == 1)
            #expect(try await APIUser.query(on: app.db).filter(\.$authProvider == "duo-oidc").count() == 0)
        }
    }

    @Test func callbackUsesTheClientSecretPostShapeWhenBasicAuthIsRejected() async throws {
        let idToken = try await signedToken(TokenSpec(subject: "post-shape-subject"))
        try await withProvider(mode: .rejectBasicAuth(idToken: idToken)) { app, provider in
            let location = try await completeLogin(on: app)
            #expect(location == "/")
            #expect(await provider.log.authorizedFlags() == [true, false])
            let bodies = await provider.log.requests.map(\.body)
            #expect(bodies.last?.contains("code_verifier=") == true)
            #expect(bodies.last?.contains("client_secret=") == true)
            #expect(try await userCount(subject: "post-shape-subject", on: app) == 1)
        }
    }

    // MARK: - ssoCallback: ID token refusals

    @Test func callbackRefusesAnExpiredIDToken() async throws {
        let idToken = try await signedToken(TokenSpec(subject: "expired-subject", expiresIn: -600))
        try await withProvider(mode: .succeed(idToken: idToken)) { app, _ in
            let location = try await completeLogin(on: app)
            #expect(location == "/login?error=sso_failed")
            #expect(try await userCount(subject: "expired-subject", on: app) == 0)
        }
    }

    @Test func callbackRefusesAnIDTokenSignedWithAnUntrustedKey() async throws {
        let idToken = try await signedToken(TokenSpec(subject: "forged-subject", key: untrustedSigningKey))
        try await withProvider(mode: .succeed(idToken: idToken)) { app, _ in
            let location = try await completeLogin(on: app)
            #expect(location == "/login?error=sso_failed")
            #expect(try await userCount(subject: "forged-subject", on: app) == 0)
        }
    }

    @Test func callbackRefusesAnIDTokenFromAnotherIssuer() async throws {
        let idToken = try await signedToken(
            TokenSpec(issuer: "http://127.0.0.1/other-issuer", subject: "wrong-issuer-subject"))
        try await withProvider(mode: .succeed(idToken: idToken)) { app, _ in
            let location = try await completeLogin(on: app)
            #expect(location == "/login?error=sso_failed")
            #expect(try await userCount(subject: "wrong-issuer-subject", on: app) == 0)
        }
    }

    // MARK: - ssoCallback: upsert

    @Test func callbackIsRefusedWhenALocalAccountHoldsTheUsername() async throws {
        let idToken = try await signedToken(TokenSpec(subject: "collision-subject", username: "localholder"))
        try await withProvider(mode: .succeed(idToken: idToken)) { app, _ in
            let local = try await makeTestUser(on: app, username: "localholder", role: "user")
            let location = try await completeLogin(on: app)
            #expect(location == "/login?error=sso_failed")
            // The local account is not claimed by the SSO subject.
            let reloaded = try #require(try await APIUser.find(local.id, on: app.db))
            #expect(reloaded.externalSubject == nil)
            #expect(reloaded.authProvider != "duo-oidc")
            #expect(try await userCount(subject: "collision-subject", on: app) == 0)
        }
    }

    @Test func displayNameFallsBackToGivenAndFamilyNameWhenNameIsBlank() async throws {
        let idToken = try await signedToken(
            TokenSpec(subject: "given-family-subject", name: "  ", givenName: "Ada", familyName: "Lovelace"))
        try await withProvider(mode: .succeed(idToken: idToken)) { app, _ in
            let location = try await completeLogin(on: app)
            #expect(location == "/")
            let user = try #require(
                try await APIUser.query(on: app.db).filter(\.$externalSubject == "given-family-subject").first())
            #expect(user.displayName == "Ada Lovelace")
        }
    }

    @Test func displayNameStaysNilWhenNoNameClaimIsSent() async throws {
        let idToken = try await signedToken(
            TokenSpec(subject: "no-name-subject", name: nil, givenName: nil, familyName: " "))
        try await withProvider(mode: .succeed(idToken: idToken)) { app, _ in
            let location = try await completeLogin(on: app)
            #expect(location == "/")
            let user = try #require(
                try await APIUser.query(on: app.db).filter(\.$externalSubject == "no-name-subject").first())
            #expect(user.displayName == nil)
        }
    }

    @Test func allowlistPromotionOfAnExistingUserIsAuditedOnce() async throws {
        let idToken = try await signedToken(TokenSpec(subject: "promoted-subject", username: "promoteme"))
        try await withProvider(mode: .succeed(idToken: idToken)) { app, _ in
            let existing = APIUser(
                username: "promoteme", passwordHash: "", role: UserRole.user.rawValue,
                authProvider: "duo-oidc", externalSubject: "promoted-subject")
            try await existing.save(on: app.db)
            app.ssoAdminUsers = ["promoteme"]

            #expect(try await completeLogin(on: app) == "/")
            let promoted = try #require(try await APIUser.find(existing.id, on: app.db))
            #expect(promoted.role == UserRole.admin.rawValue)

            let changes = try await APIAuditLogEntry.query(on: app.db)
                .filter(\.$action == AuditAction.userRoleChanged.rawValue)
                .all()
            let entry = try #require(changes.first)
            #expect(changes.count == 1)
            #expect(entry.actorUsername == "sso")
            #expect(entry.targetID == existing.id?.uuidString)
            let metadata = entry.metadata ?? ""
            #expect(metadata.contains("sso_allowlist"))
            #expect(metadata.contains(UserRole.admin.rawValue))

            // A second login keeps the role, so it records no second change.
            #expect(try await completeLogin(on: app) == "/")
            let after = try await APIAuditLogEntry.query(on: app.db)
                .filter(\.$action == AuditAction.userRoleChanged.rawValue)
                .count()
            #expect(after == 1)
        }
    }
}
