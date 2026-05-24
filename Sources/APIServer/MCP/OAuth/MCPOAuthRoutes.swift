// APIServer/MCP/OAuth/MCPOAuthRoutes.swift
//
// The Phase-2 browser OAuth 2.1 flow (Chickadee as its own authorization
// server):
//
//   GET  /oauth/authorize  — validate the client/redirect/PKCE, require a
//                            logged-in instructor/admin, render the consent
//                            screen.  Unauthenticated users are bounced through
//                            /login (returnTo stashed in the session).
//   POST /oauth/authorize  — record consent, mint a single-use PKCE code, and
//                            redirect back to the client with code + state.
//   POST /oauth/token      — exchange the code (+ PKCE verifier) for a short
//                            access token + a long rotating refresh token, or
//                            rotate a refresh token for a fresh pair.
//
// The access token's subject is the human; the agent (OAuth client) rides along
// in the client_id/agent_name claims for audit attribution.  Codes and refresh
// tokens are stored only as SHA-256 hashes.
// https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization

import Core
import Crypto
import Fluent
import Foundation
import Vapor

struct MCPOAuthRoutes: Sendable {
    let endpoints: MCPEndpoints
    let accessTokenTTLSeconds: Int
    let grantTTLDays: Int

    /// Session key holding the authorize URL a user was bounced to /login from;
    /// honored by `postLoginRedirect`.
    static let returnToSessionKey = "mcpOAuthReturnTo"

    // MARK: - GET /oauth/authorize

    @Sendable
    func authorizeForm(req: Request) async throws -> Response {
        let query = try AuthorizeQuery(req)

        // The client + redirect_uri must validate before we trust the redirect
        // target for any error response (open-redirect guard).
        guard
            let client = try await MCPOAuthClient.query(on: req.db)
                .filter(\.$clientID == query.clientID).first()
        else {
            throw Abort(.badRequest, reason: "Unknown client_id.")
        }
        guard client.redirectURIs.contains(query.redirectURI) else {
            throw Abort(.badRequest, reason: "redirect_uri is not registered for this client.")
        }

        guard query.responseType == "code" else {
            return redirect(query.redirectURI, error: "unsupported_response_type", state: query.state)
        }
        guard !query.codeChallenge.isEmpty, query.codeChallengeMethod == "S256" else {
            return redirect(query.redirectURI, error: "invalid_request", state: query.state)
        }
        let scopes = resolveScopes(query.scope)
        guard !scopes.isEmpty else {
            return redirect(query.redirectURI, error: "invalid_scope", state: query.state)
        }

        guard let user = req.auth.get(APIUser.self) else {
            // Stash the full authorize request and send the human to log in;
            // postLoginRedirect brings them back here.
            req.session.data[Self.returnToSessionKey] = req.url.string
            return req.redirect(to: "/login")
        }

        return try await renderConsent(
            req, client: client, scopes: scopes, query: query, notPermitted: !user.isInstructor)
    }

    // MARK: - POST /oauth/authorize

    @Sendable
    func authorizeSubmit(req: Request) async throws -> Response {
        guard let user = req.auth.get(APIUser.self), user.isInstructor, let userID = user.id else {
            throw Abort(.forbidden, reason: "Only instructors and admins may authorize agents.")
        }
        let form = try req.content.decode(ConsentForm.self)
        guard
            let client = try await MCPOAuthClient.query(on: req.db)
                .filter(\.$clientID == form.clientID).first(),
            client.redirectURIs.contains(form.redirectURI)
        else {
            throw Abort(.badRequest, reason: "Invalid client or redirect_uri.")
        }
        let state = form.state ?? ""
        guard form.decision == "authorize" else {
            return redirect(form.redirectURI, error: "access_denied", state: state)
        }
        let scopes = resolveScopes(form.scope)
        guard !scopes.isEmpty, !form.codeChallenge.isEmpty, form.codeChallengeMethod == "S256" else {
            return redirect(form.redirectURI, error: "invalid_request", state: state)
        }

        let code = Self.randomToken()
        let authCode = MCPAuthorizationCode(
            codeHash: sha256HexDigest(code),
            clientID: client.clientID,
            userID: userID,
            redirectURI: form.redirectURI,
            codeChallenge: form.codeChallenge,
            codeChallengeMethod: form.codeChallengeMethod,
            scope: scopes.map(\.rawValue).sorted().joined(separator: " "),
            expiresAt: Date().addingTimeInterval(60))
        try await authCode.save(on: req.db)
        return redirect(form.redirectURI, code: code, state: state)
    }

    // MARK: - POST /oauth/token

    @Sendable
    func token(req: Request) async throws -> Response {
        guard let authority = req.application.mcpTokenAuthority else {
            return Self.tokenError(.internalServerError, "server_error")
        }
        let form = try req.content.decode(TokenForm.self)
        switch form.grantType {
        case "authorization_code":
            return try await exchangeCode(req, form: form, authority: authority)
        case "refresh_token":
            return try await rotateRefresh(req, form: form, authority: authority)
        default:
            return Self.tokenError(.badRequest, "unsupported_grant_type")
        }
    }

    private func exchangeCode(
        _ req: Request, form: TokenForm, authority: MCPTokenAuthority
    ) async throws -> Response {
        guard let code = form.code, let verifier = form.codeVerifier, let redirectURI = form.redirectURI
        else {
            return Self.tokenError(.badRequest, "invalid_request")
        }
        guard
            let authCode = try await MCPAuthorizationCode.query(on: req.db)
                .filter(\.$codeHash == sha256HexDigest(code)).first(),
            !authCode.consumed,
            authCode.expiresAt > Date()
        else {
            return Self.tokenError(.badRequest, "invalid_grant")
        }
        // Single-use: burn the code before any further work so a replay loses.
        authCode.consumed = true
        try await authCode.save(on: req.db)

        guard
            authCode.redirectURI == redirectURI,
            form.clientID == nil || form.clientID == authCode.clientID,
            Self.pkceMatches(verifier: verifier, challenge: authCode.codeChallenge),
            let user = try await APIUser.find(authCode.userID, on: req.db)
        else {
            return Self.tokenError(.badRequest, "invalid_grant")
        }

        let client = try await MCPOAuthClient.query(on: req.db)
            .filter(\.$clientID == authCode.clientID).first()
        let refresh = Self.randomToken()
        let grant = MCPGrant(
            userID: authCode.userID, clientID: authCode.clientID, scope: authCode.scope,
            refreshTokenHash: sha256HexDigest(refresh),
            expiresAt: Date().addingTimeInterval(TimeInterval(grantTTLDays) * 86_400))
        try await grant.save(on: req.db)

        let access = try await mintAccess(
            authority, subject: user.username, scope: authCode.scope,
            clientID: authCode.clientID, agentName: client?.name)
        return try tokenSuccess(req, access: access, refresh: refresh, scope: authCode.scope)
    }

    private func rotateRefresh(
        _ req: Request, form: TokenForm, authority: MCPTokenAuthority
    ) async throws -> Response {
        guard let refreshToken = form.refreshToken else {
            return Self.tokenError(.badRequest, "invalid_request")
        }
        guard
            let grant = try await MCPGrant.query(on: req.db)
                .filter(\.$refreshTokenHash == sha256HexDigest(refreshToken)).first(),
            !grant.revoked,
            grant.expiresAt > Date(),
            let user = try await APIUser.find(grant.userID, on: req.db)
        else {
            return Self.tokenError(.badRequest, "invalid_grant")
        }
        // Rotate: the presented refresh token is now spent.  (Reuse-detection —
        // revoking the grant when an already-rotated token reappears — lands
        // with /revoke in the next PR.)
        let newRefresh = Self.randomToken()
        grant.refreshTokenHash = sha256HexDigest(newRefresh)
        grant.lastUsedAt = Date()
        try await grant.save(on: req.db)

        let client = try await MCPOAuthClient.query(on: req.db)
            .filter(\.$clientID == grant.clientID).first()
        let access = try await mintAccess(
            authority, subject: user.username, scope: grant.scope,
            clientID: grant.clientID, agentName: client?.name)
        return try tokenSuccess(req, access: access, refresh: newRefresh, scope: grant.scope)
    }

    // MARK: - Helpers

    private func mintAccess(
        _ authority: MCPTokenAuthority, subject: String, scope: String,
        clientID: String, agentName: String?
    ) async throws -> String {
        try await authority.mint(
            subject: subject,
            scopes: parseScopes(scope),
            issuer: endpoints.issuer,
            audience: endpoints.resource,
            ttlSeconds: accessTokenTTLSeconds,
            clientID: clientID,
            agentName: agentName)
    }

    private func renderConsent(
        _ req: Request, client: MCPOAuthClient, scopes: Set<ContentScope>,
        query: AuthorizeQuery, notPermitted: Bool
    ) async throws -> Response {
        let ordered = ContentScope.allCases.filter { scopes.contains($0) }
        let context = ConsentContext(
            currentUser: req.currentUserContext,
            clientName: client.name,
            scopeLabels: ordered.map(Self.scopeLabel),
            scopeRaw: ordered.map(\.rawValue).joined(separator: " "),
            clientID: client.clientID,
            redirectURI: query.redirectURI,
            state: query.state,
            codeChallenge: query.codeChallenge,
            codeChallengeMethod: query.codeChallengeMethod,
            notPermitted: notPermitted)
        let view = try await req.view.render("oauth-consent", context)
        return try await view.encodeResponse(for: req)
    }

    /// Keeps only valid content scopes; an empty/absent request defaults to the
    /// full content scope set.
    private func resolveScopes(_ scope: String?) -> Set<ContentScope> {
        guard let scope, !scope.trimmingCharacters(in: .whitespaces).isEmpty else {
            return Set(ContentScope.allCases)
        }
        return Set(scope.split(separator: " ").compactMap { ContentScope(rawValue: String($0)) })
    }

    private func parseScopes(_ scope: String) -> Set<ContentScope> {
        Set(scope.split(separator: " ").compactMap { ContentScope(rawValue: String($0)) })
    }

    private static func scopeLabel(_ scope: ContentScope) -> String {
        switch scope {
        case .read: return "Read course content (assignments, etc.)"
        case .write: return "Create and edit course content"
        }
    }

    private func tokenSuccess(_ req: Request, access: String, refresh: String, scope: String) throws -> Response {
        let response = Response(status: .ok)
        try response.content.encode(
            TokenResponse(
                accessToken: access, tokenType: "Bearer", expiresIn: accessTokenTTLSeconds,
                refreshToken: refresh, scope: scope), as: .json)
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return response
    }

    private static func tokenError(_ status: HTTPResponseStatus, _ error: String) -> Response {
        let response = Response(status: status)
        response.headers.contentType = .json
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        response.body = .init(string: "{\"error\":\"\(error)\"}")
        return response
    }

    /// 303 redirect carrying `code` + `state` query items (empty ones dropped).
    private func redirect(_ uri: String, code: String, state: String) -> Response {
        redirect(uri, items: [("code", code), ("state", state)])
    }

    /// 303 redirect carrying `error` + `state` query items.
    private func redirect(_ uri: String, error: String, state: String) -> Response {
        redirect(uri, items: [("error", error), ("state", state)])
    }

    private func redirect(_ uri: String, items: [(String, String)]) -> Response {
        var components = URLComponents(string: uri)
        var queryItems = components?.queryItems ?? []
        for (name, value) in items where !value.isEmpty {
            queryItems.append(URLQueryItem(name: name, value: value))
        }
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        let target = components?.url?.absoluteString ?? uri
        let response = Response(status: .seeOther)
        response.headers.replaceOrAdd(name: .location, value: target)
        return response
    }

    private static func pkceMatches(verifier: String, challenge: String) -> Bool {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) == challenge
    }

    private static func randomToken() -> String {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &rng) }
        return base64url(Data(bytes))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Request / response shapes

/// Parsed `/oauth/authorize` query parameters.
private struct AuthorizeQuery {
    let responseType: String
    let clientID: String
    let redirectURI: String
    let scope: String?
    let state: String
    let codeChallenge: String
    let codeChallengeMethod: String

    init(_ req: Request) throws {
        guard
            let clientID = req.query[String.self, at: "client_id"],
            let redirectURI = req.query[String.self, at: "redirect_uri"]
        else {
            throw Abort(.badRequest, reason: "Missing client_id or redirect_uri.")
        }
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.responseType = req.query[String.self, at: "response_type"] ?? ""
        self.scope = req.query[String.self, at: "scope"]
        self.state = req.query[String.self, at: "state"] ?? ""
        self.codeChallenge = req.query[String.self, at: "code_challenge"] ?? ""
        self.codeChallengeMethod = req.query[String.self, at: "code_challenge_method"] ?? ""
    }
}

private struct ConsentForm: Content {
    var clientID: String
    var redirectURI: String
    var scope: String
    var state: String?
    var codeChallenge: String
    var codeChallengeMethod: String
    var decision: String

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case redirectURI = "redirect_uri"
        case scope, state, decision
        case codeChallenge = "code_challenge"
        case codeChallengeMethod = "code_challenge_method"
    }
}

private struct TokenForm: Content {
    var grantType: String
    var code: String?
    var redirectURI: String?
    var clientID: String?
    var codeVerifier: String?
    var refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case grantType = "grant_type"
        case code
        case redirectURI = "redirect_uri"
        case clientID = "client_id"
        case codeVerifier = "code_verifier"
        case refreshToken = "refresh_token"
    }
}

private struct TokenResponse: Content {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
    let refreshToken: String
    let scope: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }
}

private struct ConsentContext: Encodable {
    let currentUser: CurrentUserContext?
    let clientName: String
    let scopeLabels: [String]
    let scopeRaw: String
    let clientID: String
    let redirectURI: String
    let state: String
    let codeChallenge: String
    let codeChallengeMethod: String
    let notPermitted: Bool
}
