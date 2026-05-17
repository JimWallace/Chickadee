import Fluent
import Foundation
import Vapor
import XCTVapor
import XCTest

@testable import chickadee_server

final class SecurityAndHealthTests: XCTestCase {

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

    func testUserFileNamespaceAllowsStudentOwnNamespace() async throws {
        let userID = UUID()
        try await withApp(try await makeNamespaceApp(user: makeUser(id: userID, role: "student"))) { app in
            try await app.asyncTest(.GET, "/jupyterlite/files/users/\(userID.uuidString.lowercased())/assignment.ipynb")
            { res in
                XCTAssertEqual(res.status, .ok)
            }
        }
    }

    func testUserFileNamespaceRejectsDifferentStudentNamespace() async throws {
        try await withApp(try await makeNamespaceApp(user: makeUser(role: "student"))) { app in
            try await app.asyncTest(.GET, "/jupyterlite/files/users/\(UUID().uuidString.lowercased())/assignment.ipynb")
            { res in
                XCTAssertEqual(res.status, .forbidden)
            }
        }
    }

    func testUserFileNamespaceAllowsInstructorAcrossNamespaces() async throws {
        try await withApp(try await makeNamespaceApp(user: makeUser(role: "instructor"))) { app in
            try await app.asyncTest(.GET, "/jupyterlite/files/users/\(UUID().uuidString.lowercased())/assignment.ipynb")
            { res in
                XCTAssertEqual(res.status, .ok)
            }
        }
    }

    func testUserFileNamespaceRequiresAuthenticationForGuardedPaths() async throws {
        try await withApp(try await makeNamespaceApp(user: nil)) { app in
            try await app.asyncTest(.GET, "/jupyterlite/files/users/\(UUID().uuidString.lowercased())/assignment.ipynb")
            { res in
                XCTAssertEqual(res.status, .unauthorized)
            }
        }
    }

    func testUserFileNamespaceIgnoresUnguardedPaths() async throws {
        try await withApp(try await makeNamespaceApp(user: nil)) { app in
            try await app.asyncTest(.GET, "/ok") { res in
                XCTAssertEqual(res.status, .ok)
            }
        }
    }

    func testSecurityHeadersMiddlewareAddsExpectedHeaders() async throws {
        try await withApp(try await makeSecurityHeadersApp()) { app in
            try await app.asyncTest(.GET, "/headers") { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(res.headers.first(name: "X-Content-Type-Options"), "nosniff")
                XCTAssertEqual(res.headers.first(name: "X-Frame-Options"), "SAMEORIGIN")
                XCTAssertEqual(res.headers.first(name: "Referrer-Policy"), "strict-origin-when-cross-origin")
                XCTAssertEqual(res.headers.first(name: "Cross-Origin-Opener-Policy"), "same-origin")
                XCTAssertEqual(res.headers.first(name: "Cross-Origin-Resource-Policy"), "same-origin")
            }
        }
    }

    func testCSPFormActionDefaultsToSelfOnly() async throws {
        try await withApp(try await makeSecurityHeadersApp()) { app in
            try await app.asyncTest(.GET, "/headers") { res in
                let csp = res.headers.first(name: "Content-Security-Policy") ?? ""
                XCTAssertTrue(
                    csp.contains("form-action 'self'"),
                    "expected form-action 'self' in CSP, got: \(csp)"
                )
            }
        }
    }

    func testCSPFormActionIncludesIdPOriginWhenSSOConfigured() async throws {
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
                XCTAssertTrue(
                    csp.contains("form-action 'self' https://idp.example.com"),
                    "expected end_session_endpoint origin in form-action, got: \(csp)"
                )
            }
        }
    }

    func testCSPOriginExtractionHandlesSchemeHostPort() {
        XCTAssertEqual(
            SecurityHeadersMiddleware.cspOrigin(of: "https://idp.example.com/oauth/logout"),
            "https://idp.example.com"
        )
        XCTAssertEqual(
            SecurityHeadersMiddleware.cspOrigin(of: "http://127.0.0.1:9001/logout?foo=bar"),
            "http://127.0.0.1:9001"
        )
        XCTAssertNil(SecurityHeadersMiddleware.cspOrigin(of: "not a url"))
        XCTAssertNil(SecurityHeadersMiddleware.cspOrigin(of: "mailto:nobody@example.com"))
    }

    func testLeafErrorMiddlewareReturnsJSONForAPIRoutes() async throws {
        try await withApp(try await makeLeafErrorApp(configureViews: false)) { app in
            try await app.asyncTest(.GET, "/api/boom") { res in
                XCTAssertEqual(res.status, .badRequest)
                XCTAssertEqual(res.headers.contentType?.description, "application/json; charset=utf-8")
                XCTAssertTrue(res.body.string.contains(#""reason":"api exploded""#))
            }
        }
    }

    func testLeafErrorMiddlewareRendersHTMLForBrowserRoutes() async throws {
        try await withApp(try await makeLeafErrorApp(configureViews: true)) { app in
            try await app.asyncTest(.GET, "/boom") { res in
                XCTAssertEqual(res.status, .notFound)
                XCTAssertEqual(res.headers.contentType, .html)
                XCTAssertTrue(res.body.string.contains("This page doesn't exist"))
            }
        }
    }

    func testHealthRouteReturnsOKWhenDatabaseIsReachable() async throws {
        try await withApp(try await makeHealthApp(withDatabase: true)) { app in
            await app.workerActivityStore.markActive(workerID: "worker-1", hostname: "test-host")

            try await app.asyncTest(.GET, "/health") { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(res.body.string.contains(#""status":"ok""#))
                XCTAssertTrue(res.body.string.contains(#""db":"ok""#))
                XCTAssertTrue(res.body.string.contains(#""recentActivity":true"#))
            }
        }
    }

    func testHealthRouteReportsNoRecentRunnerActivityWhenIdle() async throws {
        try await withApp(try await makeHealthApp(withDatabase: true)) { app in
            try await app.asyncTest(.GET, "/health") { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertTrue(res.body.string.contains(#""status":"ok""#))
                XCTAssertTrue(res.body.string.contains(#""db":"ok""#))
                XCTAssertTrue(res.body.string.contains(#""recentActivity":false"#))
            }
        }
    }
}
