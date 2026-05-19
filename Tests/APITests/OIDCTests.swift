import Fluent
import JWT
import Testing
import XCTVapor

@testable import APIServer

// `.serialized` because every test mutates process env vars under a single
// helper; without serialization the env mutations would race.  EnvTestLock
// (cross-suite) plus this within-suite serialization keeps the env
// snapshots intact.  TODO(migration): drop after Phase 4 if we move OIDC
// config off env vars.
@Suite(.serialized) struct OIDCTests {

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

    private struct NoOpJWTAlgorithm: JWTAlgorithm {
        let name = "noop"

        func sign(_ plaintext: some DataProtocol) throws -> [UInt8] {
            Array(plaintext)
        }

        func verify(_ signature: some DataProtocol, signs plaintext: some DataProtocol) throws -> Bool {
            true
        }
    }

    private func withEnvironment(
        _ values: [String: String?],
        perform operation: @Sendable () async throws -> Void
    ) async throws {
        // Cross-suite env serialization: AuthModeGatingTests, AppConfigTests,
        // DatabaseConfigurationTests also mutate env vars.  Without this lock
        // their setenv/unsetenv races have shown up as OIDC tests reading
        // wrong values mid-test (#603 first run).
        try await withAsyncEnvLock {
            let overrides = values.map { EnvironmentOverride(key: $0.key, value: $0.value) }
            defer {
                for override in overrides.reversed() {
                    override.restore()
                }
            }
            try await operation()
        }
    }

    private func makeOIDCApp(publicBaseURL: String? = nil) async throws -> Application {
        let app = try await Application.make(Environment(name: "testing", arguments: ["test"]))
        app.securityConfiguration = AppSecurityConfiguration(
            publicBaseURL: publicBaseURL.flatMap(URL.init(string:)),
            enforceHTTPS: false,
            trustForwardedProto: true,
            sessionCookieSecure: false
        )
        return app
    }

    private func makeMockOIDCProvider(
        discoveryPath: String,
        discoveryStatus: HTTPResponseStatus = .ok,
        jwksStatus: HTTPResponseStatus = .ok,
        jwksBody: String = #"{"keys":[]}"#
    ) async throws -> (app: Application, port: Int) {
        let app = try await Application.make(Environment(name: "testing", arguments: ["test"]))
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0

        app.get(.catchall) { req -> Response in
            switch req.url.path {
            case discoveryPath:
                guard let port = req.application.http.server.shared.localAddress?.port else {
                    throw Abort(.internalServerError, reason: "mock OIDC provider did not bind a port")
                }
                let issuerBase = "http://127.0.0.1:\(port)"
                let issuer = issuerBase + "/issuer"
                let authorizationEndpoint = issuerBase + "/authorize"
                let tokenEndpoint = issuerBase + "/token"
                let jwksURI = issuerBase + "/keys"
                let discovery = OIDCDiscovery(
                    issuer: issuer,
                    authorizationEndpoint: authorizationEndpoint,
                    tokenEndpoint: tokenEndpoint,
                    jwksURI: jwksURI,
                    revocationEndpoint: nil,
                    endSessionEndpoint: nil
                )
                let response = try Response(
                    status: discoveryStatus,
                    body: .init(data: JSONEncoder().encode(discovery))
                )
                response.headers.contentType = .json
                return response
            case "/keys":
                let response = Response(status: jwksStatus, body: .init(string: jwksBody))
                response.headers.contentType = .json
                return response
            default:
                return Response(status: .notFound)
            }
        }

        app.environment.arguments = ["serve"]
        try await app.asyncBoot()
        try await app.startup()
        guard let port = app.http.server.shared.localAddress?.port else {
            throw Abort(.internalServerError, reason: "mock OIDC provider did not expose a bound port")
        }
        return (app, port)
    }

    @Test func oidcLoadBuildsRedirectURIAndFetchesDiscoveryFromConfiguredBaseURL() async throws {
        let provider = try await makeMockOIDCProvider(
            discoveryPath: "/oidc/test-client/.well-known/openid-configuration"
        )
        try await withApp(provider.app) { _ in
            try await withEnvironment([
                "OIDC_CLIENT_ID": "test-client",
                "OIDC_CLIENT_SECRET": "super-secret",
                "OIDC_AUTH_SERVER": "http://127.0.0.1:\(provider.port)/oidc/test-client/",
                "OIDC_CALLBACK": "oidc/callback",
                // Mock IdP runs on http://127.0.0.1; allow loopback for test fixtures
                // (issue #563 hardens the validator against production misconfig).
                "OIDC_ALLOW_INSECURE": "true",
            ]) {
                try await withApp(try await makeOIDCApp(publicBaseURL: "https://courses.example.edu/")) { app in
                    let config = try await OIDCConfiguration.load(from: app)

                    #expect(config.clientID == "test-client")
                    #expect(config.clientSecret == "super-secret")
                    #expect(config.redirectURI == "https://courses.example.edu/oidc/callback")
                    #expect(config.discovery.issuer == "http://127.0.0.1:\(provider.port)/issuer")
                }
            }
        }
    }

    @Test func oidcLoadAcceptsFullyQualifiedDiscoveryURLAndDefaultCallback() async throws {
        let provider = try await makeMockOIDCProvider(
            discoveryPath: "/custom/.well-known/openid-configuration"
        )
        try await withApp(provider.app) { _ in
            try await withEnvironment([
                "OIDC_CLIENT_ID": "test-client",
                "OIDC_CLIENT_SECRET": "super-secret",
                "OIDC_AUTH_SERVER": "http://127.0.0.1:\(provider.port)/custom/.well-known/openid-configuration",
                "OIDC_CALLBACK": "",
                "OIDC_ALLOW_INSECURE": "true",
            ]) {
                try await withApp(try await makeOIDCApp()) { app in
                    let config = try await OIDCConfiguration.load(from: app)
                    #expect(config.redirectURI == "http://localhost:8080/auth/sso/callback")
                }
            }
        }
    }

    @Test func oidcLoadFailsWhenClientIDIsMissing() async throws {
        try await withEnvironment([
            "OIDC_CLIENT_ID": "   ",
            "OIDC_CLIENT_SECRET": "super-secret",
            "OIDC_AUTH_SERVER": "",
            "OIDC_CALLBACK": "",
        ]) {
            try await withApp(try await makeOIDCApp()) { app in
                await expectOIDCLoadError(
                    from: app, abortStatus: .internalServerError, messageContains: "OIDC_CLIENT_ID")
            }
        }
    }

    @Test func oidcLoadFailsWhenClientSecretIsMissing() async throws {
        try await withEnvironment([
            "OIDC_CLIENT_ID": "test-client",
            "OIDC_CLIENT_SECRET": "   ",
            "OIDC_AUTH_SERVER": "",
            "OIDC_CALLBACK": "",
        ]) {
            try await withApp(try await makeOIDCApp()) { app in
                await expectOIDCLoadError(
                    from: app, abortStatus: .internalServerError, messageContains: "OIDC_CLIENT_SECRET")
            }
        }
    }

    @Test func oidcLoadFailsWhenDiscoveryFetchReturnsNonOKStatus() async throws {
        let provider = try await makeMockOIDCProvider(
            discoveryPath: "/oidc/test-client/.well-known/openid-configuration",
            discoveryStatus: .badGateway
        )
        try await withApp(provider.app) { _ in
            try await withEnvironment([
                "OIDC_CLIENT_ID": "test-client",
                "OIDC_CLIENT_SECRET": "super-secret",
                "OIDC_AUTH_SERVER": "http://127.0.0.1:\(provider.port)/oidc/test-client",
                "OIDC_ALLOW_INSECURE": "true",
            ]) {
                try await withApp(try await makeOIDCApp()) { app in
                    await expectOIDCLoadError(
                        from: app, abortStatus: .internalServerError, messageContains: "OIDC discovery failed")
                }
            }
        }
    }

    @Test func oidcLoadFailsWhenJWKSFetchReturnsNonOKStatus() async throws {
        let provider = try await makeMockOIDCProvider(
            discoveryPath: "/oidc/test-client/.well-known/openid-configuration",
            jwksStatus: .serviceUnavailable
        )
        try await withApp(provider.app) { _ in
            try await withEnvironment([
                "OIDC_CLIENT_ID": "test-client",
                "OIDC_CLIENT_SECRET": "super-secret",
                "OIDC_AUTH_SERVER": "http://127.0.0.1:\(provider.port)/oidc/test-client",
                "OIDC_ALLOW_INSECURE": "true",
            ]) {
                try await withApp(try await makeOIDCApp()) { app in
                    await expectOIDCLoadError(
                        from: app, abortStatus: .internalServerError, messageContains: "OIDC JWKS fetch failed")
                }
            }
        }
    }

    @Test func oidcLoadFailsWhenJWKSIsMalformed() async throws {
        let provider = try await makeMockOIDCProvider(
            discoveryPath: "/oidc/test-client/.well-known/openid-configuration",
            jwksBody: "not-json"
        )
        try await withApp(provider.app) { _ in
            try await withEnvironment([
                "OIDC_CLIENT_ID": "test-client",
                "OIDC_CLIENT_SECRET": "super-secret",
                "OIDC_AUTH_SERVER": "http://127.0.0.1:\(provider.port)/oidc/test-client",
            ]) {
                try await withApp(try await makeOIDCApp()) { app in
                    await #expect(throws: (any Error).self) {
                        try await OIDCConfiguration.load(from: app)
                    }
                }
            }
        }
    }

    @Test func oidcIDTokenClaimsVerifyAcceptsNonExpiredTokens() async throws {
        let claims = OIDCIDTokenClaims(
            sub: .init(value: "subject"),
            iss: .init(value: "https://issuer.example"),
            aud: .init(value: ["client-id"]),
            exp: .init(value: Date().addingTimeInterval(300)),
            iat: .init(value: Date()),
            name: "Jane Doe",
            preferredName: "Jane",
            givenName: "Jane",
            familyName: "Doe",
            preferredUsername: "jdoe",
            email: "jdoe@example.com"
        )

        try await claims.verify(using: NoOpJWTAlgorithm())
    }

    @Test func oidcIDTokenClaimsVerifyRejectsExpiredTokens() async throws {
        let claims = OIDCIDTokenClaims(
            sub: .init(value: "subject"),
            iss: .init(value: "https://issuer.example"),
            aud: .init(value: ["client-id"]),
            exp: .init(value: Date().addingTimeInterval(-300)),
            iat: .init(value: Date().addingTimeInterval(-600))
        )

        await #expect(throws: (any Error).self) {
            try await claims.verify(using: NoOpJWTAlgorithm())
        }
    }

    // MARK: - Async throw helpers

    /// Runs `OIDCConfiguration.load(from:)` and asserts it throws an `AbortError`
    /// with the given status whose message contains `messageContains`.
    private func expectOIDCLoadError(
        from app: Application,
        abortStatus: HTTPResponseStatus,
        messageContains: String
    ) async {
        do {
            _ = try await OIDCConfiguration.load(from: app)
            Issue.record("Expected OIDCConfiguration.load to throw")
        } catch {
            #expect((error as? AbortError)?.status == abortStatus)
            #expect("\(error)".contains(messageContains))
        }
    }
}
