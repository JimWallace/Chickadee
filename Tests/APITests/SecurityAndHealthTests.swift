import Fluent
import Foundation
import Testing
import Vapor
import XCTVapor

@testable import chickadee_server

@Suite struct SecurityAndHealthTests {

    private struct InjectAuthMiddleware: AsyncMiddleware {
        let user: APIUser?

        func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
            if let user {
                request.auth.login(user)
            }
            return try await next.respond(to: request)
        }
    }

    private func makeUser(id: UUID = UUID(), role: String) -> APIUser {
        APIUser(id: id, username: "test-\(role)-\(id.uuidString)", passwordHash: "unused", role: role)
    }

    private func makeNamespaceApp(user: APIUser?) async throws -> Application {
        let app = try await Application.make(.testing)
        app.middleware.use(InjectAuthMiddleware(user: user))
        app.middleware.use(UserFileNamespaceMiddleware())
        app.get("ok") { _ in
            Response(status: .ok, body: .init(string: "ok"))
        }
        app.get("jupyterlite", "files", "users", ":userID", "assignment.ipynb") { _ in
            Response(status: .ok, body: .init(string: "notebook"))
        }
        return app
    }

    private func makeSecurityHeadersApp() async throws -> Application {
        let app = try await Application.make(.testing)
        app.middleware.use(SecurityHeadersMiddleware())
        app.get("headers") { _ in
            Response(status: .ok, body: .init(string: "ok"))
        }
        return app
    }

    private func makeLeafErrorApp(configureViews: Bool) async throws -> Application {
        let app = try await Application.make(.testing)
        app.middleware.use(LeafErrorMiddleware())
        if configureViews {
            configureLeaf(app)
        }
        app.get("api", "boom") { _ async throws -> Response in
            throw Abort(.badRequest, reason: "api exploded")
        }
        app.get("boom") { _ async throws -> Response in
            throw Abort(.notFound, reason: "page missing")
        }
        // Bare `Abort` sites (no `reason:`) — used to verify the friendlyReason
        // substitution that makes user-facing output consistent with the
        // explicit-reason path.
        app.get("bare-404") { _ async throws -> Response in throw Abort(.notFound) }
        app.get("bare-403") { _ async throws -> Response in throw Abort(.forbidden) }
        app.get("bare-400") { _ async throws -> Response in throw Abort(.badRequest) }
        app.get("api", "bare-500") { _ async throws -> Response in
            throw Abort(.internalServerError)
        }
        return app
    }

    private func makeHealthApp(withDatabase: Bool) async throws -> Application {
        let app = try await Application.make(.testing)
        if withDatabase {
            try await configureTestDatabase(app)
        }
        try app.register(collection: HealthRoutes())
        return app
    }

    @Test func userFileNamespaceAllowsStudentOwnNamespace() async throws {
        let userID = UUID()
        try await withApp(try await makeNamespaceApp(user: makeUser(id: userID, role: "student"))) { app in
            try await app.asyncTest(.GET, "/jupyterlite/files/users/\(userID.uuidString.lowercased())/assignment.ipynb")
            { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test func userFileNamespaceRejectsDifferentStudentNamespace() async throws {
        try await withApp(try await makeNamespaceApp(user: makeUser(role: "student"))) { app in
            try await app.asyncTest(.GET, "/jupyterlite/files/users/\(UUID().uuidString.lowercased())/assignment.ipynb")
            { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test func userFileNamespaceAllowsInstructorAcrossNamespaces() async throws {
        try await withApp(try await makeNamespaceApp(user: makeUser(role: "instructor"))) { app in
            try await app.asyncTest(.GET, "/jupyterlite/files/users/\(UUID().uuidString.lowercased())/assignment.ipynb")
            { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test func userFileNamespaceRequiresAuthenticationForGuardedPaths() async throws {
        try await withApp(try await makeNamespaceApp(user: nil)) { app in
            try await app.asyncTest(.GET, "/jupyterlite/files/users/\(UUID().uuidString.lowercased())/assignment.ipynb")
            { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test func userFileNamespaceIgnoresUnguardedPaths() async throws {
        try await withApp(try await makeNamespaceApp(user: nil)) { app in
            try await app.asyncTest(.GET, "/ok") { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test func securityHeadersMiddlewareAddsExpectedHeaders() async throws {
        try await withApp(try await makeSecurityHeadersApp()) { app in
            try await app.asyncTest(.GET, "/headers") { res in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "X-Content-Type-Options") == "nosniff")
                #expect(res.headers.first(name: "X-Frame-Options") == "SAMEORIGIN")
                #expect(res.headers.first(name: "Referrer-Policy") == "strict-origin-when-cross-origin")
                #expect(res.headers.first(name: "Cross-Origin-Opener-Policy") == "same-origin")
                #expect(res.headers.first(name: "Cross-Origin-Resource-Policy") == "same-origin")
            }
        }
    }

    @Test func cSPFormActionDefaultsToSelfOnly() async throws {
        try await withApp(try await makeSecurityHeadersApp()) { app in
            try await app.asyncTest(.GET, "/headers") { res in
                let csp = res.headers.first(name: "Content-Security-Policy") ?? ""
                #expect(
                    csp.contains("form-action 'self'"),
                    "expected form-action 'self' in CSP, got: \(csp)"
                )
            }
        }
    }

    @Test func cSPFormActionIncludesIdPOriginWhenSSOConfigured() async throws {
        // Regression: CSP form-action 'self' alone blocks the SSO logout
        // redirect chain (POST /logout → 303 → end_session_endpoint), which
        // Chrome and recent Firefox enforce across redirects.  Loading an
        // OIDC config with an end_session_endpoint must extend form-action
        // with that IdP origin so the "Log out" button actually navigates.
        try await withApp(try await makeSecurityHeadersApp()) { app in
            app.oidcConfig = OIDCConfiguration(
                clientID: "id",
                clientSecret: "secret",
                redirectURI: "http://localhost:8080/auth/sso/callback",
                discovery: OIDCDiscovery(
                    issuer: "https://idp.example.com",
                    authorizationEndpoint: "https://idp.example.com/oauth/authorize",
                    tokenEndpoint: "https://idp.example.com/oauth/token",
                    jwksURI: "https://idp.example.com/oauth/jwks",
                    revocationEndpoint: nil,
                    endSessionEndpoint: "https://idp.example.com/oauth/logout"
                ),
                claimConfig: OIDCClaimConfig()
            )
            try await app.asyncTest(.GET, "/headers") { res in
                let csp = res.headers.first(name: "Content-Security-Policy") ?? ""
                #expect(
                    csp.contains("form-action 'self' https://idp.example.com"),
                    "expected end_session_endpoint origin in form-action, got: \(csp)"
                )
            }
        }
    }

    @Test func cSPOriginExtractionHandlesSchemeHostPort() {
        #expect(
            SecurityHeadersMiddleware.cspOrigin(of: "https://idp.example.com/oauth/logout") == "https://idp.example.com"
        )
        #expect(
            SecurityHeadersMiddleware.cspOrigin(of: "http://127.0.0.1:9001/logout?foo=bar") == "http://127.0.0.1:9001")
        #expect(SecurityHeadersMiddleware.cspOrigin(of: "not a url") == nil)
        #expect(SecurityHeadersMiddleware.cspOrigin(of: "mailto:nobody@example.com") == nil)
    }

    @Test func leafErrorMiddlewareReturnsJSONForAPIRoutes() async throws {
        try await withApp(try await makeLeafErrorApp(configureViews: false)) { app in
            try await app.asyncTest(.GET, "/api/boom") { res in
                #expect(res.status == .badRequest)
                #expect(res.headers.contentType?.description == "application/json; charset=utf-8")
                #expect(res.body.string.contains(#""reason":"api exploded""#))
                // Status code is now included in the JSON envelope for symmetry
                // with the HTML page (where the user sees the big "400" tile).
                #expect(res.body.string.contains(#""status":400"#))
            }
        }
    }

    @Test func leafErrorMiddlewareRendersHTMLForBrowserRoutes() async throws {
        try await withApp(try await makeLeafErrorApp(configureViews: true)) { app in
            try await app.asyncTest(.GET, "/boom") { res in
                #expect(res.status == .notFound)
                #expect(res.headers.contentType == .html)
                // Explicit reason from `Abort(.notFound, reason: "page missing")`
                // is rendered verbatim — the old template hard-coded a canned
                // 404 message that clobbered typed-error context.  The
                // middleware's friendlyReason() only fills in when the reason
                // is empty or matches the generic status reasonPhrase.
                #expect(
                    res.body.string.contains("page missing"),
                    "Explicit Abort reason should render verbatim: \(res.body.string.prefix(400))"
                )
            }
        }
    }

    @Test func leafErrorMiddlewareSubstitutesFriendlyDefaultsForBareAborts() async throws {
        // `#(message)` in the Leaf template HTML-escapes the apostrophe in
        // "couldn't" / "don't" to `&#39;`, so the assertions look for the
        // apostrophe-free portion of each canonical message.
        try await withApp(try await makeLeafErrorApp(configureViews: true)) { app in
            try await app.asyncTest(.GET, "/bare-404") { res in
                #expect(res.status == .notFound)
                #expect(
                    res.body.string.contains("find that page"),
                    "Bare 404 should get the friendly default; body did not contain expected substring."
                )
            }
            try await app.asyncTest(.GET, "/bare-403") { res in
                #expect(res.status == .forbidden)
                #expect(
                    res.body.string.contains("have permission to view this page"),
                    "Bare 403 should get the friendly default; body did not contain expected substring."
                )
            }
            try await app.asyncTest(.GET, "/bare-400") { res in
                #expect(res.status == .badRequest)
                #expect(
                    res.body.string.contains("understand that request"),
                    "Bare 400 should get the friendly default; body did not contain expected substring."
                )
            }
        }
    }

    @Test func leafErrorMiddlewareJSONEnvelopeIncludesFriendlyDefaultForBareAbort() async throws {
        try await withApp(try await makeLeafErrorApp(configureViews: false)) { app in
            try await app.asyncTest(.GET, "/api/bare-500") { res in
                #expect(res.status == .internalServerError)
                #expect(res.body.string.contains(#""status":500"#))
                #expect(
                    res.body.string.contains("Something went wrong on our end"),
                    "Bare 500 JSON should get the friendly default: \(res.body.string)"
                )
            }
        }
    }

    @Test func friendlyReasonPreservesExplicitContextualReason() {
        // Typed errors like `WebAssignmentError.notFound(resource: "Assignment 'foo'")`
        // produce a contextual reason ("Assignment 'foo' not found").  The
        // middleware must NOT replace those with the generic default.
        #expect(friendlyReason(status: .notFound, reason: "Assignment 'foo' not found") == "Assignment 'foo' not found")
        #expect(
            friendlyReason(status: .forbidden, reason: "You do not have permission to edit assignments.")
                == "You do not have permission to edit assignments.")
        // But a reason that matches the HTTP reasonPhrase exactly (i.e., a
        // bare `Abort(.notFound)`) gets the friendly substitution.
        #expect(friendlyReason(status: .notFound, reason: "Not Found") == "We couldn't find that page.")
        // Empty reasons get the friendly substitution too.
        #expect(friendlyReason(status: .forbidden, reason: "") == "You don't have permission to view this page.")
        // Whitespace-only reasons are treated as empty.
        #expect(friendlyReason(status: .badRequest, reason: "   ") == "We couldn't understand that request.")
    }

    @Test func healthRouteReturnsOKWhenDatabaseIsReachable() async throws {
        try await withApp(try await makeHealthApp(withDatabase: true)) { app in
            await app.workerActivityStore.markActive(workerID: "worker-1", hostname: "test-host")

            try await app.asyncTest(.GET, "/health") { res in
                #expect(res.status == .ok)
                #expect(res.body.string.contains(#""status":"ok""#))
                #expect(res.body.string.contains(#""db":"ok""#))
                #expect(res.body.string.contains(#""recentActivity":true"#))
            }
        }
    }

    @Test func healthRouteReportsNoRecentRunnerActivityWhenIdle() async throws {
        try await withApp(try await makeHealthApp(withDatabase: true)) { app in
            try await app.asyncTest(.GET, "/health") { res in
                #expect(res.status == .ok)
                #expect(res.body.string.contains(#""status":"ok""#))
                #expect(res.body.string.contains(#""db":"ok""#))
                #expect(res.body.string.contains(#""recentActivity":false"#))
            }
        }
    }
}
