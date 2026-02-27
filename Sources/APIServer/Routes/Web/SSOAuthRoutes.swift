// APIServer/Routes/Web/SSOAuthRoutes.swift
//
// SSO authentication routes — registered only when AUTH_MODE is `sso` or `dual`.
//
// Implements the OAuth 2.0 Authorization Code Flow with PKCE against UWaterloo's
// DUO OIDC provider. After a successful callback, the user is upserted in the
// local database and a Vapor session is established (same mechanism as local login).
//
//   GET /auth/sso/start     → generate PKCE + state, redirect to IdP authorization URL
//   GET /auth/sso/callback  → validate state, exchange code, verify ID token, upsert user

import Vapor
import Fluent
import JWT
import Crypto
import Foundation

struct SSOAuthRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("auth", "sso", "start",    use: ssoStart)
        routes.get("auth", "sso", "callback", use: ssoCallback)
    }

    // MARK: - GET /auth/sso/start

    @Sendable
    func ssoStart(req: Request) async throws -> Response {
        guard let config = req.application.oidcConfig else {
            req.logger.error("SSO start called but oidcConfig is not loaded")
            return req.redirect(to: "/login?error=sso_not_configured")
        }

        // PKCE: generate random 32-byte code_verifier, then SHA-256 → base64url code_challenge
        var rng = SystemRandomNumberGenerator()
        let codeVerifierBytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let codeVerifier = Data(codeVerifierBytes).base64URLEncoded()
        let codeChallenge = Data(SHA256.hash(data: Data(codeVerifier.utf8))).base64URLEncoded()

        // State token for CSRF protection
        let stateBytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let state = Data(stateBytes).base64URLEncoded()

        // Persist in session so callback can validate
        req.session.data["oidc_state"]    = state
        req.session.data["oidc_verifier"] = codeVerifier

        // Build the IdP authorization URL
        var components = URLComponents(string: config.discovery.authorizationEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "client_id",             value: config.clientID),
            URLQueryItem(name: "response_type",         value: "code"),
            URLQueryItem(name: "scope",                 value: "openid profile email groups"),
            URLQueryItem(name: "redirect_uri",          value: config.redirectURI),
            URLQueryItem(name: "state",                 value: state),
            URLQueryItem(name: "code_challenge",        value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        guard let authURL = components?.url?.absoluteString else {
            req.logger.error("Failed to build authorization URL from: \(config.discovery.authorizationEndpoint)")
            return req.redirect(to: "/login?error=sso_failed")
        }

        return req.redirect(to: authURL)
    }

    // MARK: - GET /auth/sso/callback

    @Sendable
    func ssoCallback(req: Request) async throws -> Response {
        guard let config = req.application.oidcConfig else {
            req.logger.error("SSO callback called but oidcConfig is not loaded")
            return req.redirect(to: "/login?error=sso_not_configured")
        }

        // Handle IdP-side errors (e.g., user denied consent)
        if let idpError = req.query[String.self, at: "error"] {
            let description = req.query[String.self, at: "error_description"] ?? idpError
            req.logger.warning("IdP returned error in SSO callback: \(description)")
            return req.redirect(to: "/login?error=sso_denied")
        }

        // CSRF: validate state matches what we stored in the session
        let returnedState = req.query[String.self, at: "state"] ?? ""
        let storedState   = req.session.data["oidc_state"] ?? ""
        let codeVerifier  = req.session.data["oidc_verifier"] ?? ""

        // Always clear session values — whether we succeed or fail below
        req.session.data["oidc_state"]    = nil
        req.session.data["oidc_verifier"] = nil

        guard !returnedState.isEmpty, returnedState == storedState else {
            req.logger.warning("SSO callback: state mismatch (possible CSRF or stale session)")
            return req.redirect(to: "/login?error=sso_failed")
        }

        guard let code = req.query[String.self, at: "code"] else {
            req.logger.warning("SSO callback: missing authorization code")
            return req.redirect(to: "/login?error=sso_failed")
        }

        // Exchange authorization code for tokens
        let tokenResponse: OIDCTokenResponse
        do {
            let response = try await req.client.post(
                URI(string: config.discovery.tokenEndpoint)
            ) { tokenReq in
                tokenReq.headers.contentType = .urlEncodedForm
                try tokenReq.content.encode([
                    "grant_type":    "authorization_code",
                    "code":          code,
                    "redirect_uri":  config.redirectURI,
                    "client_id":     config.clientID,
                    "client_secret": config.clientSecret,
                    "code_verifier": codeVerifier,
                ] as [String: String])
            }
            guard response.status == .ok else {
                req.logger.error("Token exchange returned HTTP \(response.status.code)")
                return req.redirect(to: "/login?error=sso_failed")
            }
            tokenResponse = try response.content.decode(OIDCTokenResponse.self)
        } catch {
            req.logger.error("Token exchange failed: \(error)")
            return req.redirect(to: "/login?error=sso_failed")
        }

        // Verify ID token signature + expiry, then decode claims
        let claims: OIDCIDTokenClaims
        do {
            claims = try await req.application.jwt.keys.verify(
                tokenResponse.idToken,
                as: OIDCIDTokenClaims.self
            )
        } catch {
            req.logger.error("ID token verification failed: \(error)")
            return req.redirect(to: "/login?error=sso_failed")
        }

        // Validate issuer and audience manually (JWTKit verifies signature + exp only)
        guard claims.iss.value == config.discovery.issuer else {
            req.logger.error("ID token issuer mismatch: got \(claims.iss.value), expected \(config.discovery.issuer)")
            return req.redirect(to: "/login?error=sso_failed")
        }
        guard claims.aud.value.contains(config.clientID) else {
            req.logger.error("ID token audience does not contain client_id")
            return req.redirect(to: "/login?error=sso_failed")
        }

        // Upsert user in the local database
        let user: APIUser
        do {
            user = try await upsertUser(claims: claims, on: req)
        } catch {
            req.logger.error("Failed to upsert SSO user (sub=\(claims.sub.value)): \(error)")
            return req.redirect(to: "/login?error=sso_failed")
        }

        // Establish session — identical to local login
        req.auth.login(user)
        req.session.authenticate(user)
        return req.redirect(to: "/")
    }

    // MARK: - User upsert

    /// Look up a user by (auth_provider, external_subject); create if not found.
    /// Updates mutable profile fields (email, display_name, last_login_at) on every login.
    private func upsertUser(claims: OIDCIDTokenClaims, on req: Request) async throws -> APIUser {
        let subject = claims.sub.value
        let username = claims.winaccountname?.nilIfEmpty() ?? subject

        // Prefer full name from 'name' claim; fall back to given + family
        let displayName: String? = {
            if let n = claims.name?.nilIfEmpty() { return n }
            let parts = [claims.givenName, claims.familyName].compactMap { $0?.nilIfEmpty() }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }()

        if let existing = try await APIUser.query(on: req.db)
            .filter(\.$authProvider == "duo-oidc")
            .filter(\.$externalSubject == subject)
            .first()
        {
            existing.email        = claims.email
            existing.displayName  = displayName ?? existing.displayName
            existing.lastLoginAt  = Date()
            try await existing.save(on: req.db)
            return existing
        }

        let newUser = APIUser(
            username:        username,
            passwordHash:    "",            // SSO users have no local password
            role:            "student",
            authProvider:    "duo-oidc",
            externalSubject: subject,
            email:           claims.email,
            displayName:     displayName,
            lastLoginAt:     Date()
        )
        try await newUser.save(on: req.db)
        return newUser
    }
}

// MARK: - Helpers

private extension String {
    /// Returns nil when the string is empty, self otherwise.
    func nilIfEmpty() -> String? { isEmpty ? nil : self }
}

private extension Data {
    /// Base64url encoding (RFC 4648 §5): replaces +/→-_, strips padding.
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
