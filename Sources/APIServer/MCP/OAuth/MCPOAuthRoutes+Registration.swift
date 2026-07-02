// APIServer/MCP/OAuth/MCPOAuthRoutes+Registration.swift
//
// POST /oauth/register (RFC 7591 Dynamic Client Registration) and
// POST /oauth/revoke (RFC 7009 token revocation), with their validation
// helpers.
//
// Split out of MCPOAuthRoutes.swift along its MARK seams (#1122, following the
// v0.4.37 large-source splits).  No logic change.

import Core
import Fluent
import Foundation
import Vapor

extension MCPOAuthRoutes {
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
        // Open registration is anonymous, but the new client is inert until an
        // instructor consents — still worth a record of what was registered.
        await AuditLogger.record(
            action: .mcpClientRegistered,
            targetType: .oauthClient,
            targetID: clientID,
            metadata: ["client_name": name, "redirect_uri_count": String(redirects.count)],
            on: req
        )

        let response = RegistrationResponse(
            clientID: clientID,
            clientIDIssuedAt: Int(Date().timeIntervalSince1970),
            clientName: name,
            redirectURIs: redirects,
            grantTypes: ["authorization_code", "refresh_token"],
            responseTypes: ["code"],
            tokenEndpointAuthMethod: "none",
            // Advertise the content surface's scopes (same source as the
            // .well-known docs).  The admin resource's `diagnostics:read` is
            // discovered via its own protected-resource metadata and clamped at
            // /authorize, so it isn't listed here — keeping DCR content-focused.
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
}
