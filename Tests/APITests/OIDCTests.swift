import XCTest
import XCTVapor
@testable import chickadee_server
import JWT

final class OIDCTests: XCTestCase {

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

    private func makeOIDCApp(publicBaseURL: String? = nil) async throws -> Application {
        let app = try await Application.make(.testing)
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
        let app = try await Application.make(.testing)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        app.environment.arguments = ["serve"]

        app.get(.catchall) { req -> Response in
            switch req.url.path {
            case discoveryPath:
                guard let port = req.application.http.server.shared.localAddress?.port else {
                    throw Abort(.internalServerError, reason: "mock OIDC provider did not bind a port")
                }
                let issuerBase = "http://127.0.0.1:\(port)"
                let discovery = OIDCDiscovery(
                    issuer: issuerBase + "/issuer",
                    authorizationEndpoint: issuerBase + "/authorize",
                    tokenEndpoint: issuerBase + "/token",
                    jwksURI: issuerBase + "/keys"
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

        try await app.asyncBoot()
        try await app.startup()
        guard let port = app.http.server.shared.localAddress?.port else {
            throw Abort(.internalServerError, reason: "mock OIDC provider did not expose a bound port")
        }
        return (app, port)
    }

    func testOIDCLoadBuildsRedirectURIAndFetchesDiscoveryFromConfiguredBaseURL() async throws {
        let provider = try await makeMockOIDCProvider(
            discoveryPath: "/oidc/test-client/.well-known/openid-configuration"
        )
        try await withApp(provider.app) { _ in
            try await withEnvironment([
                "OIDC_CLIENT_ID": "test-client",
                "OIDC_CLIENT_SECRET": "super-secret",
                "OIDC_AUTH_SERVER": "http://127.0.0.1:\(provider.port)/oidc/test-client/",
                "OIDC_CALLBACK": "oidc/callback"
            ]) {
                try await withTestApp({ try await makeOIDCApp(publicBaseURL: "https://courses.example.edu/") }) { app in
                    let config = try await OIDCConfiguration.load(from: app)

                    XCTAssertEqual(config.clientID, "test-client")
                    XCTAssertEqual(config.clientSecret, "super-secret")
                    XCTAssertEqual(config.redirectURI, "https://courses.example.edu/oidc/callback")
                    XCTAssertEqual(config.discovery.issuer, "http://127.0.0.1:\(provider.port)/issuer")
                }
            }
        }
    }

    func testOIDCLoadAcceptsFullyQualifiedDiscoveryURLAndDefaultCallback() async throws {
        let provider = try await makeMockOIDCProvider(
            discoveryPath: "/custom/.well-known/openid-configuration"
        )
        try await withApp(provider.app) { _ in
            try await withEnvironment([
                "OIDC_CLIENT_ID": "test-client",
                "OIDC_CLIENT_SECRET": "super-secret",
                "OIDC_AUTH_SERVER": "http://127.0.0.1:\(provider.port)/custom/.well-known/openid-configuration",
                "OIDC_CALLBACK": ""
            ]) {
                try await withTestApp({ try await makeOIDCApp() }) { app in
                    let config = try await OIDCConfiguration.load(from: app)
                    XCTAssertEqual(config.redirectURI, "http://localhost:8080/auth/sso/callback")
                }
            }
        }
    }

    func testOIDCLoadFailsWhenClientIDIsMissing() async throws {
        try await withEnvironment([
            "OIDC_CLIENT_ID": "   ",
            "OIDC_CLIENT_SECRET": "super-secret",
            "OIDC_AUTH_SERVER": "",
            "OIDC_CALLBACK": ""
        ]) {
            try await withTestApp({ try await makeOIDCApp() }) { app in
                await XCTAssertThrowsErrorAsync(try await OIDCConfiguration.load(from: app)) { error in
                    XCTAssertEqual((error as? AbortError)?.status, .internalServerError)
                    XCTAssertTrue("\(error)".contains("OIDC_CLIENT_ID"))
                }
            }
        }
    }

    func testOIDCLoadFailsWhenClientSecretIsMissing() async throws {
        try await withEnvironment([
            "OIDC_CLIENT_ID": "test-client",
            "OIDC_CLIENT_SECRET": "   ",
            "OIDC_AUTH_SERVER": "",
            "OIDC_CALLBACK": ""
        ]) {
            try await withTestApp({ try await makeOIDCApp() }) { app in
                await XCTAssertThrowsErrorAsync(try await OIDCConfiguration.load(from: app)) { error in
                    XCTAssertEqual((error as? AbortError)?.status, .internalServerError)
                    XCTAssertTrue("\(error)".contains("OIDC_CLIENT_SECRET"))
                }
            }
        }
    }

    func testOIDCLoadFailsWhenDiscoveryFetchReturnsNonOKStatus() async throws {
        let provider = try await makeMockOIDCProvider(
            discoveryPath: "/oidc/test-client/.well-known/openid-configuration",
            discoveryStatus: .badGateway
        )
        try await withApp(provider.app) { _ in
            try await withEnvironment([
                "OIDC_CLIENT_ID": "test-client",
                "OIDC_CLIENT_SECRET": "super-secret",
                "OIDC_AUTH_SERVER": "http://127.0.0.1:\(provider.port)/oidc/test-client"
            ]) {
                try await withTestApp({ try await makeOIDCApp() }) { app in
                    await XCTAssertThrowsErrorAsync(try await OIDCConfiguration.load(from: app)) { error in
                        XCTAssertEqual((error as? AbortError)?.status, .internalServerError)
                        XCTAssertTrue("\(error)".contains("OIDC discovery failed"))
                    }
                }
            }
        }
    }

    func testOIDCLoadFailsWhenJWKSFetchReturnsNonOKStatus() async throws {
        let provider = try await makeMockOIDCProvider(
            discoveryPath: "/oidc/test-client/.well-known/openid-configuration",
            jwksStatus: .serviceUnavailable
        )
        try await withApp(provider.app) { _ in
            try await withEnvironment([
                "OIDC_CLIENT_ID": "test-client",
                "OIDC_CLIENT_SECRET": "super-secret",
                "OIDC_AUTH_SERVER": "http://127.0.0.1:\(provider.port)/oidc/test-client"
            ]) {
                try await withTestApp({ try await makeOIDCApp() }) { app in
                    await XCTAssertThrowsErrorAsync(try await OIDCConfiguration.load(from: app)) { error in
                        XCTAssertEqual((error as? AbortError)?.status, .internalServerError)
                        XCTAssertTrue("\(error)".contains("OIDC JWKS fetch failed"))
                    }
                }
            }
        }
    }

    func testOIDCLoadFailsWhenJWKSIsMalformed() async throws {
        let provider = try await makeMockOIDCProvider(
            discoveryPath: "/oidc/test-client/.well-known/openid-configuration",
            jwksBody: "not-json"
        )
        try await withApp(provider.app) { _ in
            try await withEnvironment([
                "OIDC_CLIENT_ID": "test-client",
                "OIDC_CLIENT_SECRET": "super-secret",
                "OIDC_AUTH_SERVER": "http://127.0.0.1:\(provider.port)/oidc/test-client"
            ]) {
                try await withTestApp({ try await makeOIDCApp() }) { app in
                    await XCTAssertThrowsErrorAsync(try await OIDCConfiguration.load(from: app))
                }
            }
        }
    }

    func testOIDCIDTokenClaimsVerifyAcceptsNonExpiredTokens() async throws {
        let claims = OIDCIDTokenClaims(
            sub: .init(value: "subject"),
            iss: .init(value: "https://issuer.example"),
            aud: .init(value: ["client-id"]),
            exp: .init(value: Date().addingTimeInterval(300)),
            iat: .init(value: Date()),
            winaccountname: "jdoe",
            name: "Jane Doe",
            preferredName: "Jane",
            givenName: "Jane",
            familyName: "Doe",
            userID: "jdoe",
            studentID: "12345678",
            email: "jdoe@example.com"
        )

        try await claims.verify(using: NoOpJWTAlgorithm())
    }

    func testOIDCIDTokenClaimsVerifyRejectsExpiredTokens() async throws {
        let claims = OIDCIDTokenClaims(
            sub: .init(value: "subject"),
            iss: .init(value: "https://issuer.example"),
            aud: .init(value: ["client-id"]),
            exp: .init(value: Date().addingTimeInterval(-300)),
            iat: .init(value: Date().addingTimeInterval(-600)),
            winaccountname: nil,
            name: nil,
            preferredName: nil,
            givenName: nil,
            familyName: nil,
            userID: nil,
            studentID: nil,
            email: nil
        )

        await XCTAssertThrowsErrorAsync(try await claims.verify(using: NoOpJWTAlgorithm()))
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
