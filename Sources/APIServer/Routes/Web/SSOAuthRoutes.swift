// APIServer/Routes/Web/SSOAuthRoutes.swift
//
// SSO authentication routes — registered only when AUTH_MODE is `sso` or `dual`.
// Handlers return 501 until a real OIDC/OAuth provider is wired in.
//
//   GET /auth/sso/start     → redirect browser to identity provider
//   GET /auth/sso/callback  → receive IdP callback, establish session

import Vapor

struct SSOAuthRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("auth", "sso", "start",    use: ssoStart)
        routes.get("auth", "sso", "callback", use: ssoCallback)
    }

    // MARK: - GET /auth/sso/start

    @Sendable
    func ssoStart(req: Request) async throws -> Response {
        throw Abort(.notImplemented, reason: "SSO provider not yet configured")
    }

    // MARK: - GET /auth/sso/callback

    @Sendable
    func ssoCallback(req: Request) async throws -> Response {
        throw Abort(.notImplemented, reason: "SSO provider not yet configured")
    }
}
