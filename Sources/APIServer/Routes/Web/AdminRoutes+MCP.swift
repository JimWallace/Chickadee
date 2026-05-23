// APIServer/Routes/Web/AdminRoutes+MCP.swift
//
// Admin "MCP" tab: provision non-loginable `mcp` service accounts and mint
// short-lived access tokens for them (shown exactly once).  Token minting is
// only possible when the MCP endpoint is active (MCP_ENABLED + a resolvable
// issuer/resource + the signing authority loaded at startup).
//
// Revocation note: access tokens are stateless JWTs with no server-side
// denylist, so deleting an account stops *new* tokens being minted but cannot
// invalidate one already issued — it simply expires after its TTL.

import Core
import Fluent
import Foundation
import Vapor

extension AdminRoutes {
    // MARK: - GET /admin/mcp

    @Sendable
    func mcpPage(req: Request) async throws -> View {
        try await renderMCPPage(
            req: req, mintedToken: nil, mintedFor: nil, mintedScopes: nil,
            error: req.query[String.self, at: "error"])
    }

    // MARK: - POST /admin/mcp/accounts

    @Sendable
    func createMCPAccount(req: Request) async throws -> Response {
        struct Body: Content { var username: String }
        let username = try req.content.decode(Body.self).username
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            return req.redirect(to: "/admin/mcp?error=username_required")
        }
        if try await APIUser.query(on: req.db).filter(\.$username == username).first() != nil {
            return req.redirect(to: "/admin/mcp?error=username_taken")
        }
        // Non-loginable service account: a random bcrypt hash no password can
        // match, role=mcp (excluded from autoAssignableRoles, so no first-login
        // path can mint it), and no externalSubject for SSO to match either.
        let unusableHash = try Bcrypt.hash(UUID().uuidString + UUID().uuidString)
        let user = APIUser(username: username, passwordHash: unusableHash, role: "mcp")
        try await user.save(on: req.db)
        await AuditLogger.record(
            action: .mcpAccountCreated, targetType: .user, targetID: user.id?.uuidString,
            metadata: ["username": username], on: req)
        return req.redirect(to: "/admin/mcp")
    }

    // MARK: - POST /admin/mcp/accounts/:userID/token

    @Sendable
    func mintMCPToken(req: Request) async throws -> View {
        struct Body: Content { var scope: String? }
        let user = try await findMCPAccount(req)
        let mcp = req.application.appConfig.mcp
        guard
            mcp.enabled,
            let authority = req.application.mcpTokenAuthority,
            let endpoints = MCPEndpoints.resolve(mcp: mcp, security: req.application.appConfig.security)
        else {
            return try await renderMCPPage(
                req: req, mintedToken: nil, mintedFor: nil, mintedScopes: nil, error: "mcp_disabled")
        }
        let scopeChoice = (try? req.content.decode(Body.self))?.scope
        let scopes: Set<ContentScope> = scopeChoice == "read" ? [.read] : [.read, .write]
        let token = try await authority.mint(
            subject: user.username, scopes: scopes,
            issuer: endpoints.issuer, audience: endpoints.resource, ttlSeconds: mcp.tokenTTLSeconds)
        let scopeLabel = scopes.map(\.rawValue).sorted().joined(separator: " ")
        // Audit the mint but never the token itself.
        await AuditLogger.record(
            action: .mcpTokenMinted, targetType: .user, targetID: user.id?.uuidString,
            metadata: ["username": user.username, "scopes": scopeLabel], on: req)
        return try await renderMCPPage(
            req: req, mintedToken: token, mintedFor: user.username, mintedScopes: scopeLabel, error: nil)
    }

    // MARK: - POST /admin/mcp/accounts/:userID/delete

    @Sendable
    func deleteMCPAccount(req: Request) async throws -> Response {
        let user = try await findMCPAccount(req)
        let username = user.username
        let id = user.id?.uuidString
        try await user.delete(on: req.db)
        await AuditLogger.record(
            action: .mcpAccountDeleted, targetType: .user, targetID: id,
            metadata: ["username": username], on: req)
        return req.redirect(to: "/admin/mcp")
    }

    // MARK: - Helpers

    /// Resolves the `:userID` route parameter to an `mcp`-role user, or 404s.
    private func findMCPAccount(_ req: Request) async throws -> APIUser {
        guard
            let idString = req.parameters.get("userID"),
            let uuid = UUID(uuidString: idString),
            let user = try await APIUser.find(uuid, on: req.db),
            user.isMCPAgent
        else {
            throw Abort(.notFound)
        }
        return user
    }

    private func renderMCPPage(
        req: Request,
        mintedToken: String?,
        mintedFor: String?,
        mintedScopes: String?,
        error: String?
    ) async throws -> View {
        let mcp = req.application.appConfig.mcp
        let endpoints = MCPEndpoints.resolve(mcp: mcp, security: req.application.appConfig.security)
        let enabled = mcp.enabled && req.application.mcpTokenAuthority != nil && endpoints != nil

        let accounts = try await APIUser.query(on: req.db)
            .filter(\.$role == "mcp")
            .sort(\.$username)
            .all()
            .compactMap { user -> AdminMCPAccountRow? in
                guard let id = user.id else { return nil }
                return AdminMCPAccountRow(
                    id: id.uuidString,
                    username: user.username,
                    createdAt: user.createdAt.map { ISO8601DateFormatter().string(from: $0) } ?? "—")
            }

        let ctx = AdminMCPContext(
            currentUser: req.currentUserContext,
            activeAdminTab: "mcp",
            enabled: enabled,
            issuer: endpoints?.issuer,
            resource: endpoints?.resource,
            tokenTTLSeconds: mcp.tokenTTLSeconds,
            accounts: accounts,
            mintedToken: mintedToken,
            mintedFor: mintedFor,
            mintedScopes: mintedScopes,
            error: error)
        return try await req.view.render("admin-mcp", ctx)
    }
}
