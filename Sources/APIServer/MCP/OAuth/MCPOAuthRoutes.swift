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
import SQLKit
import Vapor

struct MCPOAuthRoutes: Sendable {
    let endpoints: MCPEndpoints
    let accessTokenTTLSeconds: Int
    let grantTTLDays: Int
    /// Cap on total dynamically-registered clients (anti-flooding backstop).
    var maxRegisteredClients: Int = 1000
    /// Cap on `redirect_uris` accepted in one registration.
    var maxRedirectURIsPerClient: Int = 5

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

        // The Authorize button POSTs here and the server 303s to the client's
        // (now-validated) redirect_uri. Browsers enforce `form-action` across
        // that redirect, so the default `form-action 'self'` would silently
        // block the hop to the connector — add the redirect origin. Likewise a
        // connector may drive this in a popup expecting a `window.opener`
        // handshake, which the default COOP `same-origin` severs; relax it.
        SecurityHeadersMiddleware.allowFormAction(
            SecurityHeadersMiddleware.cspOrigin(of: query.redirectURI), on: req)
        SecurityHeadersMiddleware.setOpenerPolicy("same-origin-allow-popups", on: req)

        guard query.responseType == "code" else {
            return redirect(query.redirectURI, error: "unsupported_response_type", state: query.state)
        }
        guard !query.codeChallenge.isEmpty, query.codeChallengeMethod == "S256" else {
            return redirect(query.redirectURI, error: "invalid_request", state: query.state)
        }
        let scopes = resolveScopes(query.scope, ceiling: req.application.appConfig.mcp.mode.scopeCeiling)
        guard !scopes.isEmpty else {
            return redirect(query.redirectURI, error: "invalid_scope", state: query.state)
        }

        guard let user = req.auth.get(APIUser.self) else {
            // Stash the full authorize request and send the human to log in;
            // postLoginRedirect brings them back here.
            req.session.data[Self.returnToSessionKey] = req.url.string
            return req.redirect(to: "/login")
        }

        let firstTimeApproval = try await Self.isFirstApproval(
            req, userID: user.id, clientID: client.clientID)

        // Mint a single-use consent token only for a permitted instructor. The
        // token (not a cookie) carries identity + CSRF protection to the POST,
        // so the submit works even when Safari/ITP drops the session cookie on
        // the cross-site hop. Non-instructors get the not-permitted view and no
        // actionable token.
        var requestToken: String?
        if let userID = user.id, user.isInstructor {
            let token = Self.randomToken()
            try await MCPConsentRequest(
                tokenHash: sha256HexDigest(token),
                userID: userID,
                clientID: client.clientID,
                redirectURI: query.redirectURI,
                scope: scopes.map(\.rawValue).sorted().joined(separator: " "),
                state: query.state,
                codeChallenge: query.codeChallenge,
                codeChallengeMethod: query.codeChallengeMethod,
                expiresAt: Date().addingTimeInterval(Self.consentRequestTTLSeconds)
            ).save(on: req.db)
            requestToken = token
        }

        let ordered = ContentScope.allCases.filter { scopes.contains($0) }
        let context = ConsentContext(
            currentUser: req.currentUserContext,
            clientName: client.name,
            scopeLabels: ordered.map(Self.scopeLabel),
            redirectHost: URLComponents(string: query.redirectURI)?.host ?? query.redirectURI,
            firstTimeApproval: firstTimeApproval,
            notPermitted: !user.isInstructor,
            requestToken: requestToken)
        return try await renderConsent(req, context: context)
    }

    /// How long a rendered consent screen stays submittable.
    static let consentRequestTTLSeconds: TimeInterval = 600

    /// True when the user holds no existing non-revoked grant for this client —
    /// drives the "you have not approved this app before" consent warning.
    private static func isFirstApproval(
        _ req: Request, userID: UUID?, clientID: String
    ) async throws -> Bool {
        guard let userID else { return true }
        let prior = try await MCPGrant.query(on: req.db)
            .filter(\.$userID == userID)
            .filter(\.$clientID == clientID)
            .filter(\.$revoked == false)
            .first()
        return prior == nil
    }

    // MARK: - POST /oauth/authorize

    @Sendable
    func authorizeSubmit(req: Request) async throws -> Response {
        // Identity + CSRF ride on the single-use consent token, not the session
        // cookie — so this works in the cross-site connector context where the
        // cookie is dropped. Look the token up by hash, then burn it.
        let form = try req.content.decode(ConsentForm.self)
        let tokenHash = sha256HexDigest(form.requestToken)
        guard
            let record = try await MCPConsentRequest.query(on: req.db)
                .filter(\.$tokenHash == tokenHash).first(),
            record.expiresAt > Date()
        else {
            throw Abort(
                .badRequest,
                reason: "This authorization request has expired or already been used. "
                    + "Restart the connection to try again.")
        }
        // Single-use: atomically burn the consent token before any further work
        // and only proceed if this submit won the burn — a concurrent replay
        // loses the conditional UPDATE and is rejected.
        guard
            try await Self.burnConsumable(
                on: req.db, table: MCPConsentRequest.schema, hashColumn: "token_hash", hash: tokenHash)
        else {
            throw Abort(
                .badRequest,
                reason: "This authorization request has expired or already been used. "
                    + "Restart the connection to try again.")
        }

        // Re-validate the client/redirect from the frozen record (defense in
        // depth — the record is server-authored, but a stale client edit could
        // have dropped the redirect URI between GET and POST).
        guard
            let client = try await MCPOAuthClient.query(on: req.db)
                .filter(\.$clientID == record.clientID).first(),
            client.redirectURIs.contains(record.redirectURI)
        else {
            throw Abort(.badRequest, reason: "Invalid client or redirect_uri.")
        }
        let state = record.state
        guard form.decision == "authorize" else {
            return redirect(record.redirectURI, error: "access_denied", state: state)
        }
        // Re-check the role from the bound user at submit time: a downgrade
        // between rendering the consent screen and submitting it must stop here.
        guard
            let user = try await APIUser.find(record.userID, on: req.db), user.isInstructor
        else {
            throw Abort(.forbidden, reason: "Only instructors and admins may authorize agents.")
        }
        let scopes = resolveScopes(record.scope, ceiling: req.application.appConfig.mcp.mode.scopeCeiling)
        guard !scopes.isEmpty, !record.codeChallenge.isEmpty, record.codeChallengeMethod == "S256" else {
            return redirect(record.redirectURI, error: "invalid_request", state: state)
        }

        let code = Self.randomToken()
        let authCode = MCPAuthorizationCode(
            codeHash: sha256HexDigest(code),
            clientID: client.clientID,
            userID: record.userID,
            redirectURI: record.redirectURI,
            codeChallenge: record.codeChallenge,
            codeChallengeMethod: record.codeChallengeMethod,
            scope: scopes.map(\.rawValue).sorted().joined(separator: " "),
            expiresAt: Date().addingTimeInterval(60))
        try await authCode.save(on: req.db)
        return redirect(record.redirectURI, code: code, state: state)
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
        let codeHash = sha256HexDigest(code)
        guard
            let authCode = try await MCPAuthorizationCode.query(on: req.db)
                .filter(\.$codeHash == codeHash).first(),
            authCode.expiresAt > Date()
        else {
            return Self.tokenError(.badRequest, "invalid_grant")
        }
        // Single-use: atomically burn the code BEFORE any further work and only
        // proceed if this request won the burn.  A concurrent replay of the same
        // code loses the conditional UPDATE and is rejected (the prior in-process
        // read-modify-write could otherwise mint two token pairs from one code).
        guard
            try await Self.burnConsumable(
                on: req.db, table: MCPAuthorizationCode.schema, hashColumn: "code_hash", hash: codeHash)
        else {
            return Self.tokenError(.badRequest, "invalid_grant")
        }

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
        let hash = sha256HexDigest(refreshToken)

        // Theft response: a token matching an already-rotated-away hash is a
        // replay — revoke the whole grant and refuse.
        if let reused = try await MCPGrant.query(on: req.db)
            .filter(\.$previousRefreshTokenHash == hash).first(), !reused.revoked
        {
            reused.revoked = true
            try await reused.save(on: req.db)
            return Self.tokenError(.badRequest, "invalid_grant")
        }

        guard
            let grant = try await MCPGrant.query(on: req.db)
                .filter(\.$refreshTokenHash == hash).first(),
            !grant.revoked,
            grant.expiresAt > Date(),
            let user = try await APIUser.find(grant.userID, on: req.db)
        else {
            return Self.tokenError(.badRequest, "invalid_grant")
        }
        // Re-authorize at refresh time: if the human is no longer an
        // instructor/admin (role downgraded or account repurposed), stop the
        // agent — revoke the grant so it can't be refreshed again.  The web
        // session loses access immediately via RoleMiddleware; this closes the
        // gap for long-lived MCP grants.
        guard user.isInstructor else {
            grant.revoked = true
            try await grant.save(on: req.db)
            return Self.tokenError(.badRequest, "invalid_grant")
        }
        // Rotate: issue a new refresh token and swap it in atomically, gated on
        // the CURRENT hash so two concurrent rotations of the same token can't
        // both win (the loser matches zero rows and is rejected as a replay).
        let newRefresh = Self.randomToken()
        let newHash = sha256HexDigest(newRefresh)
        guard try await Self.rotateRefreshHash(on: req.db, currentHash: hash, newHash: newHash) else {
            return Self.tokenError(.badRequest, "invalid_grant")
        }
        // We won the rotation: mirror the swap onto the in-memory model and
        // persist last-used telemetry (kept out of the atomic UPDATE to avoid
        // Fluent↔raw-SQL date-format skew). Only the winner reaches this save.
        grant.previousRefreshTokenHash = hash
        grant.refreshTokenHash = newHash
        grant.lastUsedAt = Date()
        try await grant.save(on: req.db)

        let client = try await MCPOAuthClient.query(on: req.db)
            .filter(\.$clientID == grant.clientID).first()
        let access = try await mintAccess(
            authority, subject: user.username, scope: grant.scope,
            clientID: grant.clientID, agentName: client?.name)
        return try tokenSuccess(req, access: access, refresh: newRefresh, scope: grant.scope)
    }

    // MARK: - POST /oauth/register (RFC 7591 Dynamic Client Registration)

    @Sendable
    func register(req: Request) async throws -> Response {
        let metadata: RegistrationRequest
        do {
            metadata = try req.content.decode(RegistrationRequest.self)
        } catch {
            return Self.registrationError("invalid_client_metadata", "Could not parse client metadata.")
        }
        let redirects = metadata.redirectURIs
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !redirects.isEmpty, redirects.allSatisfy(Self.isValidRedirectURI) else {
            return Self.registrationError(
                "invalid_redirect_uri", "redirect_uris must be HTTPS (or http on localhost) absolute URLs.")
        }
        guard redirects.count <= maxRedirectURIsPerClient else {
            return Self.registrationError(
                "invalid_redirect_uri", "Too many redirect_uris (max \(maxRedirectURIsPerClient)).")
        }
        // Backstop against /oauth/register flooding (the rate limiter is the
        // first line of defence; this bounds total rows).
        guard try await MCPOAuthClient.query(on: req.db).count() < maxRegisteredClients else {
            let response = Response(status: .tooManyRequests)
            response.headers.contentType = .json
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            response.body = .init(
                string: "{\"error\":\"temporarily_unavailable\","
                    + "\"error_description\":\"Client registration limit reached.\"}")
            return response
        }

        let name: String
        if let trimmed = metadata.clientName?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty {
            name = trimmed
        } else {
            name = "Unnamed MCP client"
        }
        let clientID = Self.randomToken()
        // Open registration: anyone may register a client, but it can do nothing
        // until an instructor/admin consents at /authorize.
        try await MCPOAuthClient(clientID: clientID, name: name, redirectURIs: redirects, isPublic: true)
            .save(on: req.db)

        let response = RegistrationResponse(
            clientID: clientID,
            clientIDIssuedAt: Int(Date().timeIntervalSince1970),
            clientName: name,
            redirectURIs: redirects,
            grantTypes: ["authorization_code", "refresh_token"],
            responseTypes: ["code"],
            tokenEndpointAuthMethod: "none",
            // Grant exactly what the discovery metadata advertises — same
            // source (MCPMode.advertisedScopes) so DCR and the .well-known docs
            // can never disagree.
            scope: req.application.appConfig.mcp.mode.advertisedScopes
                .map(\.rawValue).joined(separator: " "))
        let result = Response(status: .created)
        try result.content.encode(response, as: .json)
        result.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return result
    }

    /// Accepts HTTPS absolute URLs, plus http on loopback hosts (for local MCP
    /// clients / the Inspector).
    private static func isValidRedirectURI(_ uri: String) -> Bool {
        guard let url = URL(string: uri), let scheme = url.scheme?.lowercased(), let host = url.host
        else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && (host == "localhost" || host == "127.0.0.1" || host == "[::1]")
    }

    private static func registrationError(_ error: String, _ description: String) -> Response {
        let response = Response(status: .badRequest)
        response.headers.contentType = .json
        // RFC 6749 §5.1: credential/token-adjacent responses must not be cached.
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        response.body = .init(string: "{\"error\":\"\(error)\",\"error_description\":\"\(description)\"}")
        return response
    }

    // MARK: - POST /oauth/revoke (RFC 7009)

    @Sendable
    func revoke(req: Request) async throws -> Response {
        if let token = (try? req.content.decode(RevokeForm.self))?.token, !token.isEmpty {
            let hash = sha256HexDigest(token)
            // Match the current or just-rotated refresh-token hash.  Bound to a
            // `let` first so the trailing closure isn't read as the `if` body.
            let grant = try await MCPGrant.query(on: req.db).group(.or) { group in
                group.filter(\.$refreshTokenHash == hash)
                    .filter(\.$previousRefreshTokenHash == hash)
            }.first()
            if let grant {
                grant.revoked = true
                try await grant.save(on: req.db)
            }
        }
        // RFC 7009: respond 200 whether or not the token was recognized (an
        // opaque access token / unknown token is simply a no-op).
        return Response(status: .ok)
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

    private func renderConsent(_ req: Request, context: ConsentContext) async throws -> Response {
        let view = try await req.view.render("oauth-consent", context)
        let response = try await view.encodeResponse(for: req)
        // The consent page embeds the single-use consent token; keep it out of
        // any shared/proxy cache.
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return response
    }

    /// Keeps only valid content scopes, then clamps to the server-wide ceiling
    /// for the current MCP_MODE so a consent request can't grant more than the
    /// mode honors (read_only → {read}).  An empty/absent request defaults to
    /// the full ceiling.
    private func resolveScopes(_ scope: String?, ceiling: Set<ContentScope>) -> Set<ContentScope> {
        guard let scope, !scope.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ceiling
        }
        let requested = Set(scope.split(separator: " ").compactMap { ContentScope(rawValue: String($0)) })
        return requested.intersection(ceiling)
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

    /// Atomically flips a single-use `consumed` flag from false→true for the row
    /// whose `hashColumn` equals `hash`, returning true iff *this* call won the
    /// flip.  One conditional `UPDATE … WHERE consumed = false RETURNING`
    /// statement is atomic on both SQLite (WAL) and Postgres, so two concurrent
    /// `/token` (or `/authorize`) submits of the same code/consent token can
    /// never both win — closing the OAuth code-replay race that the prior
    /// read-check-then-save left open.  `table`/`hashColumn` are compile-time
    /// schema constants (no injection surface); only the hash is bound.
    private static func burnConsumable(
        on db: Database, table: String, hashColumn: String, hash: String
    ) async throws -> Bool {
        guard let sql = db as? SQLDatabase else { return true }
        let rows = try await sql.raw(
            "UPDATE \(unsafeRaw: table) SET consumed = true WHERE \(unsafeRaw: hashColumn) = \(bind: hash) AND consumed = false RETURNING id"
        ).all()
        return !rows.isEmpty
    }

    /// Atomically rotates a grant's refresh-token hash, gated on the *current*
    /// hash so two concurrent rotations of the same refresh token can't both
    /// succeed (the loser matches zero rows).  Returns true iff this call won the
    /// rotation; the caller then mirrors the swap onto the in-memory model and
    /// persists non-security telemetry (`lastUsedAt`).
    private static func rotateRefreshHash(
        on db: Database, currentHash: String, newHash: String
    ) async throws -> Bool {
        guard let sql = db as? SQLDatabase else { return true }
        let rows = try await sql.raw(
            "UPDATE \(unsafeRaw: MCPGrant.schema) SET previous_refresh_token_hash = refresh_token_hash, refresh_token_hash = \(bind: newHash) WHERE refresh_token_hash = \(bind: currentHash) AND revoked = false RETURNING id"
        ).all()
        return !rows.isEmpty
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
    /// The single-use consent token from the rendered form; everything else
    /// (client, redirect, scope, PKCE, the consenting user) is frozen in the
    /// server-side `MCPConsentRequest` keyed by this token.
    var requestToken: String
    var decision: String

    enum CodingKeys: String, CodingKey {
        case requestToken = "request_token"
        case decision
    }
}

private struct RegistrationRequest: Content {
    var clientName: String?
    var redirectURIs: [String]
    var grantTypes: [String]?
    var responseTypes: [String]?
    var tokenEndpointAuthMethod: String?
    var scope: String?

    enum CodingKeys: String, CodingKey {
        case clientName = "client_name"
        case redirectURIs = "redirect_uris"
        case grantTypes = "grant_types"
        case responseTypes = "response_types"
        case tokenEndpointAuthMethod = "token_endpoint_auth_method"
        case scope
    }
}

private struct RegistrationResponse: Content {
    let clientID: String
    let clientIDIssuedAt: Int
    let clientName: String
    let redirectURIs: [String]
    let grantTypes: [String]
    let responseTypes: [String]
    let tokenEndpointAuthMethod: String
    let scope: String

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientIDIssuedAt = "client_id_issued_at"
        case clientName = "client_name"
        case redirectURIs = "redirect_uris"
        case grantTypes = "grant_types"
        case responseTypes = "response_types"
        case tokenEndpointAuthMethod = "token_endpoint_auth_method"
        case scope
    }
}

private struct RevokeForm: Content {
    var token: String?
    var tokenTypeHint: String?

    enum CodingKeys: String, CodingKey {
        case token
        case tokenTypeHint = "token_type_hint"
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
    /// Host portion of the redirect URI, shown prominently so the human can spot
    /// an unexpected destination (DCR client names are self-asserted).
    let redirectHost: String
    /// True when the user has never approved this client — drives a warning.
    let firstTimeApproval: Bool
    let notPermitted: Bool
    /// Single-use consent token embedded in the form; nil for the not-permitted
    /// view (no submittable form is shown).
    let requestToken: String?
}
