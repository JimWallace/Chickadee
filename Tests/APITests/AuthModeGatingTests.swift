// Tests/APITests/AuthModeGatingTests.swift
//
// Verify that SSO routes are gated by authMode:
//   - .local → /auth/sso/start and /auth/sso/callback return 404 (not registered)
//   - .sso   → both routes return 303 redirect (registered; no oidcConfig → error redirect)
//   - .dual  → same as .sso; local login routes still present

import Fluent
import Foundation
import Testing
import XCTVapor

@testable import chickadee_server

// `.serialized` until the migration is complete (Phase 4) and we audit which
// suites need it — one test mutates `OIDC_CALLBACK` and each test brings up a
// real Vapor `Application` + DB.  TODO(migration): relax after Phase 4.
@Suite(.serialized) struct AuthModeGatingTests {

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

    @Test func localMode_ssoStartReturns404() async throws {
        try await withApp(try await makeApp(authMode: .local)) { app in
            try await app.asyncTest(
                .GET, "/auth/sso/start",
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })
        }
    }

    @Test func localMode_ssoCallbackReturns404() async throws {
        try await withApp(try await makeApp(authMode: .local)) { app in
            try await app.asyncTest(
                .GET, "/auth/sso/callback",
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })
        }
    }

    // MARK: - SSO mode: routes present (redirect to error page when oidcConfig not loaded)

    @Test func ssoMode_ssoStartRedirectsWhenNotConfigured() async throws {
        try await withApp(try await makeApp(authMode: .sso)) { app in
            try await app.asyncTest(
                .GET, "/auth/sso/start",
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(
                        res.headers.first(name: .location)?.contains("sso_not_configured") == true
                    )
                })
        }
    }

    @Test func ssoMode_ssoCallbackRedirectsWhenNotConfigured() async throws {
        try await withApp(try await makeApp(authMode: .sso)) { app in
            try await app.asyncTest(
                .GET, "/auth/sso/callback",
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(
                        res.headers.first(name: .location)?.contains("sso_not_configured") == true
                    )
                })
        }
    }

    @Test func ssoMode_localLoginPostNotRegistered() async throws {
        try await withApp(try await makeApp(authMode: .sso)) { app in
            try await app.asyncTest(
                .POST, "/login",
                afterResponse: { res in
                    #expect(
                        res.status == .forbidden || res.status == .notFound,
                        "POST /login must be inaccessible in SSO mode, got \(res.status)")
                })
        }
    }

    @Test func ssoMode_registerNotRegistered() async throws {
        try await withApp(try await makeApp(authMode: .sso)) { app in
            try await app.asyncTest(
                .GET, "/register",
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })
        }
    }

    @Test func ssoMode_loginAutoRedirectsToSSOStart() async throws {
        try await withApp(try await makeApp(authMode: .sso)) { app in
            try await app.asyncTest(
                .GET, "/login",
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/auth/sso/start")
                })
        }
    }

    @Test func ssoMode_customCallbackRouteRegisteredFromEnv() async throws {
        // Cross-suite env serialization via `withAsyncEnvLock` — OIDCTests
        // also mutates OIDC_* env vars, and without serialization the two
        // suites' setenv/unsetenv calls have raced under `swift test
        // --parallel` (#603 first run).
        try await withAsyncEnvLock {
            setenv("OIDC_CALLBACK", "/oidc/duo/callback/", 1)
            defer { unsetenv("OIDC_CALLBACK") }

            try await withApp(try await makeApp(authMode: .sso)) { app in
                try await app.asyncTest(
                    .GET, "/oidc/duo/callback",
                    afterResponse: { res in
                        #expect(res.status == .seeOther)
                        #expect(
                            res.headers.first(name: .location)?.contains("sso_not_configured") == true
                        )
                    })
            }
        }
    }

    // MARK: - Dual mode: SSO routes present alongside local login

    @Test func dualMode_ssoStartRedirectsWhenNotConfigured() async throws {
        try await withApp(try await makeApp(authMode: .dual)) { app in
            try await app.asyncTest(
                .GET, "/auth/sso/start",
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.status != .notFound)
                })
        }
    }

    @Test func dualMode_localLoginStillWorks() async throws {
        try await withApp(try await makeApp(authMode: .dual)) { app in
            try await app.asyncTest(
                .GET, "/login",
                afterResponse: { res in
                    #expect(res.status != .notFound)
                })
        }
    }

    @Test func dualMode_localLoginPostStillRegistered() async throws {
        try await withApp(try await makeApp(authMode: .dual)) { app in
            try await app.asyncTest(
                .POST, "/login",
                afterResponse: { res in
                    #expect(res.status != .notFound)
                })
        }
    }
}
