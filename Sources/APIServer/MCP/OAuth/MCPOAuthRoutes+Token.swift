// APIServer/MCP/OAuth/MCPOAuthRoutes+Token.swift
//
// POST /oauth/token — exchange a single-use PKCE code for an access + refresh
// token pair, or rotate a refresh token for a fresh pair (with prior-hash theft
// detection and re-authorization of the human's role).  Also owns the atomic
// single-use primitives: `burnConsumable` (conditional UPDATE compare-and-set,
// shared with the consent submit) and `rotateRefreshHash`.
//
// Split out of MCPOAuthRoutes.swift along its MARK seams (#1122, following the
// v0.4.37 large-source splits).  No logic change.

import Core
import Crypto
import Fluent
import Foundation
import SQLKit
import Vapor

extension MCPOAuthRoutes {
    // MARK: - POST /oauth/token

    @Sendable
    func token(req: Request) async throws -> Response {
        // The signing authority is resolved per-surface inside each grant path
        // (the surface comes from the code's / grant's stored scope), so a
        // content code mints a content token and an admin code mints an admin
        // token from the right key + audience.
        let form = try req.content.decode(TokenForm.self)
        switch form.grantType {
        case "authorization_code":
            return try await exchangeCode(req, form: form)
        case "refresh_token":
            return try await rotateRefresh(req, form: form)
        default:
            return Self.tokenError(.badRequest, "unsupported_grant_type")
        }
    }

    private func exchangeCode(
        _ req: Request, form: TokenForm
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

        let surface = surfaceForScope(authCode.scope, req: req)
        guard let authority = surface.authority else {
            return Self.tokenError(.internalServerError, "server_error")
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
            surface, authority: authority, subject: user.username, scope: authCode.scope,
            clientID: authCode.clientID, agentName: client?.name)
        // Records the first access+refresh pair an agent receives after consent.
        // (Routine hourly refresh rotation is deliberately NOT logged — high
        // volume, low signal; refresh *theft* and downgrade-revoke are below.)
        await AuditLogger.record(
            action: .mcpTokenIssued,
            targetType: .user,
            targetID: authCode.userID.uuidString,
            metadata: [
                "username": user.username,
                "client_id": authCode.clientID,
                "client_name": client?.name ?? "",
                "scope": authCode.scope,
            ],
            actorOverride: user,
            on: req
        )
        return try tokenSuccess(req, access: access, refresh: refresh, scope: authCode.scope)
    }

    private func rotateRefresh(
        _ req: Request, form: TokenForm
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
            // Replay of a rotated-away token is a theft signal — record it (and
            // who/what it was for) before refusing.
            let reusedUsername = try await APIUser.find(reused.userID, on: req.db)?.username
            await AuditLogger.record(
                action: .mcpRefreshReuseDetected,
                targetType: .user,
                targetID: reused.userID.uuidString,
                metadata: [
                    "username": reusedUsername ?? reused.userID.uuidString,
                    "client_id": reused.clientID,
                ],
                actorUsernameOverride: reusedUsername,
                on: req
            )
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
        // The surface is fixed by the grant's stored scope namespace.
        let surface = surfaceForScope(grant.scope, req: req)
        guard let authority = surface.authority else {
            return Self.tokenError(.internalServerError, "server_error")
        }
        // Re-authorize at refresh time: if the human no longer holds the role
        // this surface requires (instructor+ for content, admin for diagnostics
        // — role downgraded or account repurposed), stop the agent and revoke
        // the grant so it can't be refreshed again.  The web session loses
        // access immediately via RoleMiddleware; this closes the gap for
        // long-lived MCP grants.
        guard try await surface.permits(user, db: req.db) else {
            grant.revoked = true
            try await grant.save(on: req.db)
            await AuditLogger.record(
                action: .mcpGrantRevoked,
                targetType: .user,
                targetID: grant.userID.uuidString,
                metadata: [
                    "username": user.username,
                    "client_id": grant.clientID,
                    "reason": "role_downgrade",
                ],
                actorOverride: user,
                on: req
            )
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
            surface, authority: authority, subject: user.username, scope: grant.scope,
            clientID: grant.clientID, agentName: client?.name)
        return try tokenSuccess(req, access: access, refresh: newRefresh, scope: grant.scope)
    }

    // MARK: - Token helpers

    private func mintAccess(
        _ surface: ResolvedSurface, authority: MCPTokenAuthority, subject: String, scope: String,
        clientID: String, agentName: String?
    ) async throws -> String {
        try await authority.mint(
            subject: subject,
            scopeStrings: scope.split(separator: " ").map(String.init),
            issuer: surface.issuer,
            audience: surface.audience,
            ttlSeconds: surface.accessTokenTTLSeconds,
            clientID: clientID,
            agentName: agentName)
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

    private static func pkceMatches(verifier: String, challenge: String) -> Bool {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString() == challenge
    }

    /// Atomically flips a single-use `consumed` flag from false→true for the row
    /// whose `hashColumn` equals `hash`, returning true iff *this* call won the
    /// flip.  One conditional `UPDATE … WHERE consumed = false RETURNING`
    /// statement is atomic on both SQLite (WAL) and Postgres, so two concurrent
    /// `/token` (or `/authorize`) submits of the same code/consent token can
    /// never both win — closing the OAuth code-replay race that the prior
    /// read-check-then-save left open.  `table`/`hashColumn` are compile-time
    /// schema constants (no injection surface); only the hash is bound.
    /// Internal (not private): the consent submit in
    /// MCPOAuthRoutes+Authorize.swift burns its token through the same primitive.
    static func burnConsumable(
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
}
