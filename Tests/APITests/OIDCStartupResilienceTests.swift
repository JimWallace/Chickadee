// Tests/APITests/OIDCStartupResilienceTests.swift
//
// An unreachable IdP must not stop the server from starting.
//
// The server used to fetch the OIDC discovery document before `app.execute()`
// and treat a failure as fatal. During an IdP outage the running container
// survived on the configuration it already held, but every new container died
// during startup: it never bound a port, never answered `/health`, and the
// blue-green gate refused it. The deployment could not roll forward at the one
// moment a fix had to ship.
//
// These tests pin the split that fixes it. Environment validation stays fatal,
// because no retry supplies a missing client ID. The network fetch does not:
// it degrades to "SSO unavailable" and retries on demand.

import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.timeLimit(.minutes(2))) struct OIDCStartupResilienceTests {

    /// A discovery endpoint that counts its hits and can be switched from
    /// failing to serving, so a retry after recovery is observable.
    private actor MockDiscoveryEndpoint {
        enum Mode { case failing, serving }

        private var mode: Mode
        private(set) var discoveryHits = 0

        init(mode: Mode) { self.mode = mode }

        func recordDiscoveryHit() -> Mode {
            discoveryHits += 1
            return mode
        }

        func startServing() { mode = .serving }
    }

    /// A port that refuses connections, so the fetch fails immediately rather
    /// than waiting on a DNS or connect timeout.
    private static let closedPort = 1

    private func oidcSettings(discoveryBase: String) -> OIDCEnvConfig {
        OIDCEnvConfig(
            clientID: "chickadee-test-client",
            clientSecret: "chickadee-test-secret",
            authServerOverride: discoveryBase,
            callbackPath: "/auth/sso/callback",
            usernameClaim: "preferred_username",
            emailClaim: "email",
            // The fixtures below are http:// on a loopback port, which the
            // discovery-URL guard rejects by default.
            allowInsecure: true
        )
    }

    private func makeSSOApp(discoveryBase: String) async throws -> Application {
        try await makeTestApp(
            authMode: .sso,
            appConfig: .testDefaults(authMode: .sso, oidc: oidcSettings(discoveryBase: discoveryBase))
        )
    }

    private func withMockIdP(
        mode: MockDiscoveryEndpoint.Mode,
        _ body: (String, MockDiscoveryEndpoint) async throws -> Void
    ) async throws {
        let endpoint = MockDiscoveryEndpoint(mode: mode)

        let idp = try await Application.make(Environment(name: "testing", arguments: ["test"]))
        idp.http.server.configuration.hostname = "127.0.0.1"
        idp.http.server.configuration.port = 0

        idp.get(".well-known", "openid-configuration") { req async throws -> Response in
            guard await endpoint.recordDiscoveryHit() == .serving else {
                return Response(status: .serviceUnavailable)
            }
            let port = req.application.http.server.shared.localAddress?.port ?? 0
            let base = "http://127.0.0.1:\(port)"
            let response = Response(
                status: .ok,
                body: .init(
                    string: """
                        {"issuer":"\(base)","authorization_endpoint":"\(base)/authorize",\
                        "token_endpoint":"\(base)/token","jwks_uri":"\(base)/keys"}
                        """
                )
            )
            response.headers.contentType = .json
            return response
        }

        idp.get("keys") { _ async throws -> Response in
            let response = Response(status: .ok, body: .init(string: #"{"keys":[]}"#))
            response.headers.contentType = .json
            return response
        }

        idp.environment.arguments = ["serve"]
        try await idp.asyncBoot()
        try await idp.startup()
        guard let port = idp.http.server.shared.localAddress?.port else {
            throw IssueRecorded("mock IdP failed to bind a port")
        }

        do {
            try await body("http://127.0.0.1:\(port)", endpoint)
        } catch {
            try await idp.asyncShutdown()
            throw error
        }
        try await idp.asyncShutdown()
    }

    // MARK: - Environment validation stays fatal

    @Test func validateEnvironmentRejectsAMissingClientID() async throws {
        let settings = OIDCEnvConfig(
            clientID: nil,
            clientSecret: "chickadee-test-secret",
            authServerOverride: "https://idp.example.com",
            callbackPath: "/auth/sso/callback",
            usernameClaim: "preferred_username",
            emailClaim: "email",
            allowInsecure: false
        )
        let app = try await makeTestApp(
            authMode: .sso,
            appConfig: .testDefaults(authMode: .sso, oidc: settings)
        )
        try await withApp(app) { app in
            #expect(throws: (any Error).self) {
                _ = try OIDCConfiguration.validateEnvironment(from: app)
            }
        }
    }

    @Test func validateEnvironmentAcceptsCompleteSettingsWithoutNetwork() async throws {
        let app = try await makeSSOApp(discoveryBase: "http://127.0.0.1:\(Self.closedPort)")
        try await withApp(app) { app in
            let inputs = try OIDCConfiguration.validateEnvironment(from: app)
            #expect(inputs.clientID == "chickadee-test-client")
            #expect(inputs.discoveryURL.hasSuffix("/.well-known/openid-configuration"))
        }
    }

    // MARK: - The fetch degrades instead of throwing

    @Test func resolveReturnsNilWhenTheIdPIsUnreachable() async throws {
        let app = try await makeSSOApp(discoveryBase: "http://127.0.0.1:\(Self.closedPort)")
        try await withApp(app) { app in
            let resolved = await app.resolvedOIDCConfiguration()
            #expect(resolved == nil)
            #expect(app.oidcConfig == nil)
        }
    }

    @Test func aStoredConfigurationIsReturnedWithoutFetching() async throws {
        try await withMockIdP(mode: .failing) { base, endpoint in
            let app = try await makeSSOApp(discoveryBase: base)
            try await withApp(app) { app in
                app.oidcConfig = OIDCConfiguration(
                    clientID: "already-loaded",
                    clientSecret: "secret",
                    redirectURI: "http://localhost:8080/auth/sso/callback",
                    discovery: OIDCDiscovery(
                        issuer: "https://idp.example.com",
                        authorizationEndpoint: "https://idp.example.com/authorize",
                        tokenEndpoint: "https://idp.example.com/token",
                        jwksURI: "https://idp.example.com/keys",
                        revocationEndpoint: nil,
                        endSessionEndpoint: nil
                    ),
                    claimConfig: OIDCClaimConfig()
                )

                let resolved = await app.resolvedOIDCConfiguration()
                #expect(resolved?.clientID == "already-loaded")
                #expect(await endpoint.discoveryHits == 0)
            }
        }
    }

    // MARK: - Retry behaviour

    @Test func aFailedFetchIsNotRetriedInsideTheCooldown() async throws {
        try await withMockIdP(mode: .failing) { base, endpoint in
            let app = try await makeSSOApp(discoveryBase: base)
            try await withApp(app) { app in
                #expect(await app.resolvedOIDCConfiguration() == nil)
                #expect(await endpoint.discoveryHits == 1)

                #expect(await app.resolvedOIDCConfiguration() == nil)
                #expect(await endpoint.discoveryHits == 1)
            }
        }
    }

    @Test func theCooldownExpiringAllowsAnotherAttempt() async throws {
        try await withMockIdP(mode: .failing) { base, endpoint in
            let app = try await makeSSOApp(discoveryBase: base)
            try await withApp(app) { app in
                #expect(await app.resolvedOIDCConfiguration() == nil)
                #expect(await endpoint.discoveryHits == 1)

                let afterCooldown = Date().addingTimeInterval(
                    OIDCConfigurationProvider.retryCooldown + 1
                )
                let resolved = await app.oidcConfigurationProvider.resolve(
                    app: app, now: afterCooldown
                )
                #expect(resolved == nil)
                #expect(await endpoint.discoveryHits == 2)
            }
        }
    }

    @Test func sSOBecomesAvailableOnceTheIdPRecovers() async throws {
        try await withMockIdP(mode: .failing) { base, endpoint in
            let app = try await makeSSOApp(discoveryBase: base)
            try await withApp(app) { app in
                #expect(await app.resolvedOIDCConfiguration() == nil)

                await endpoint.startServing()
                let afterCooldown = Date().addingTimeInterval(
                    OIDCConfigurationProvider.retryCooldown + 1
                )
                let resolved = await app.oidcConfigurationProvider.resolve(
                    app: app, now: afterCooldown
                )

                #expect(resolved != nil)
                #expect(resolved?.clientID == "chickadee-test-client")
                // Cached from here on: a later call performs no further fetch.
                let hitsAfterSuccess = await endpoint.discoveryHits
                #expect(await app.resolvedOIDCConfiguration() != nil)
                #expect(await endpoint.discoveryHits == hitsAfterSuccess)
            }
        }
    }

    // MARK: - Route-level degradation

    @Test func ssoStartRedirectsToLoginWhileDiscoveryIsUnavailable() async throws {
        let app = try await makeSSOApp(discoveryBase: "http://127.0.0.1:\(Self.closedPort)")
        try await withApp(app) { app in
            try await app.testing().test(.GET, "/auth/sso/start") { res in
                #expect(res.status == .seeOther || res.status == .found)
                let location = res.headers.first(name: .location) ?? ""
                #expect(location.contains("error=sso_not_configured"))
            }
        }
    }
}
