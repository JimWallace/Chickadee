// Tests/APITests/SessionIdleTimeoutMiddlewareTests.swift
//
// Unit tests for SessionIdleTimeoutMiddleware.  The middleware is exercised
// in isolation: a tiny test app that pre-authenticates a fake user with a
// configurable `lastSeenAt`, registers the middleware, and serves a
// single endpoint.  This mirrors the COEPMiddlewareTests pattern.

import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer

@Suite struct SessionIdleTimeoutMiddlewareTests {

    /// Builds a minimal Vapor app that authenticates every request as the
    /// supplied user before the middleware-under-test runs.  Returns the
    /// app — caller is responsible for shutdown via `withApp`.
    private func makeApp(
        user: APIUser,
        idleTimeoutSeconds: TimeInterval
    ) async throws -> Application {
        let app = try await Application.make(.testing)
        // The middleware-under-test reads `req.session.data` to clear OIDC
        // tokens and calls `req.session.unauthenticate`, both of which need
        // the session middleware to have initialised the session on the
        // request.
        app.sessions.use(.memory)
        app.middleware.use(app.sessions.middleware)
        // AuditLogger writes a row through `req.db` on every expiry, so a
        // database has to be in place even though no test reads it back.
        try await configureTestDatabase(app)
        app.middleware.use(PreAuthenticator(user: user))
        app.middleware.use(
            SessionIdleTimeoutMiddleware(idleTimeoutSeconds: idleTimeoutSeconds)
        )
        app.get("page") { _ in "ok" }
        app.get("api", "v1", "thing") { _ in "ok-api" }
        return app
    }

    private func makeUser(lastSeenAt: Date?) -> APIUser {
        let user = APIUser(
            id: UUID(),
            username: "jim",
            passwordHash: "x",
            role: "student",
            lastSeenAt: lastSeenAt
        )
        return user
    }

    // MARK: - Browser path

    @Test func activeBrowserRequestPassesThrough() async throws {
        let user = makeUser(lastSeenAt: Date().addingTimeInterval(-60))  // 1 min ago
        try await withApp(try await makeApp(user: user, idleTimeoutSeconds: 30 * 60)) { app in
            try await app.testable().test(.GET, "/page") { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "ok")
            }
        }
    }

    @Test func idleBrowserRequestRedirectsToLoginWithTimeoutError() async throws {
        let user = makeUser(lastSeenAt: Date().addingTimeInterval(-31 * 60))  // 31 min ago
        try await withApp(try await makeApp(user: user, idleTimeoutSeconds: 30 * 60)) { app in
            try await app.testable().test(.GET, "/page") { res async in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "/login?error=timeout")
            }
        }
    }

    // MARK: - API path

    @Test func idleAPIRequestReturns401() async throws {
        let user = makeUser(lastSeenAt: Date().addingTimeInterval(-31 * 60))
        try await withApp(try await makeApp(user: user, idleTimeoutSeconds: 30 * 60)) { app in
            try await app.testable().test(.GET, "/api/v1/thing") { res async in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test func activeAPIRequestPassesThrough() async throws {
        let user = makeUser(lastSeenAt: Date())
        try await withApp(try await makeApp(user: user, idleTimeoutSeconds: 30 * 60)) { app in
            try await app.testable().test(.GET, "/api/v1/thing") { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "ok-api")
            }
        }
    }

    // MARK: - Disabled / missing-signal short circuits

    @Test func zeroTimeoutDisablesGate() async throws {
        // Even an ancient lastSeenAt should pass through when disabled.
        let user = makeUser(lastSeenAt: Date.distantPast)
        try await withApp(try await makeApp(user: user, idleTimeoutSeconds: 0)) { app in
            try await app.testable().test(.GET, "/page") { res async in
                #expect(res.status == .ok)
            }
        }
    }

    @Test func userWithoutLastSeenAtPassesThrough() async throws {
        // Legacy rows / first-ever request after migration — the activity
        // middleware downstream will populate the column on this request,
        // so the gate must not lock the user out before they get a signal.
        let user = makeUser(lastSeenAt: nil)
        try await withApp(try await makeApp(user: user, idleTimeoutSeconds: 30 * 60)) { app in
            try await app.testable().test(.GET, "/page") { res async in
                #expect(res.status == .ok)
            }
        }
    }

}

// MARK: - Helpers

/// Minimal middleware that stuffs a pre-built `APIUser` into `req.auth` so
/// tests can exercise downstream middleware without booting the full
/// session/auth chain.  Production has no analogue — this is test-only.
private struct PreAuthenticator: AsyncMiddleware {
    let user: APIUser

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        request.auth.login(user)
        return try await next.respond(to: request)
    }
}
