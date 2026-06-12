// APIServer/MCP/OAuth/MCPAgentsRoutes.swift
//
// "Connected agents" management page (instructor/admin): lists the OAuth grants
// an agent holds on a human's behalf and lets the human revoke them.  An
// instructor sees their own grants; an admin sees every grant.  Revoking flips
// the grant's `revoked` flag — refresh stops immediately and the access token
// lapses within its short TTL.

import Fluent
import Foundation
import Vapor

struct MCPAgentsRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("agents", use: list)
        routes.post("agents", ":grantID", "revoke", use: revoke)
    }

    @Sendable
    func list(req: Request) async throws -> View {
        let user = try req.auth.require(APIUser.self)
        let isAdmin = user.isAdmin

        var builder = MCPGrant.query(on: req.db).sort(\.$createdAt, .descending)
        if !isAdmin, let userID = user.id {
            builder = builder.filter(\.$userID == userID)
        }
        let grants = try await builder.all()
        let rows = try await Self.grantRows(grants, includeOwner: isAdmin, on: req.db)
        let context = ConnectedAgentsContext(
            currentUser: req.currentUserContext, isAdmin: isAdmin, rows: rows)
        return try await req.view.render("connected-agents", context)
    }

    /// Builds display rows for the given grants — resolving client (agent)
    /// display names, and owner usernames when `includeOwner`. Shared by the
    /// instructor `/agents` page and the admin MCP panel so the two can't drift.
    static func grantRows(
        _ grants: [MCPGrant], includeOwner: Bool, on db: Database
    ) async throws -> [AgentGrantRow] {
        guard !grants.isEmpty else { return [] }
        let clients = try await MCPOAuthClient.query(on: db)
            .filter(\.$clientID ~~ Array(Set(grants.map(\.clientID)))).all()
        let clientNames = Dictionary(
            clients.map { ($0.clientID, $0.name) }, uniquingKeysWith: { first, _ in first })
        var ownerNames: [UUID: String] = [:]
        if includeOwner {
            let owners = try await APIUser.query(on: db)
                .filter(\.$id ~~ Array(Set(grants.map(\.userID)))).all()
            ownerNames = Dictionary(
                owners.compactMap { owner in owner.id.map { ($0, owner.username) } },
                uniquingKeysWith: { first, _ in first })
        }
        let formatter = ISO8601DateFormatter()
        return grants.compactMap { grant -> AgentGrantRow? in
            guard let id = grant.id else { return nil }
            return AgentGrantRow(
                id: id.uuidString,
                agentName: clientNames[grant.clientID] ?? grant.clientID,
                scope: grant.scope,
                owner: includeOwner ? (ownerNames[grant.userID] ?? "—") : nil,
                createdAt: grant.createdAt.map { formatter.string(from: $0) } ?? "—",
                lastUsedAt: grant.lastUsedAt.map { formatter.string(from: $0) },
                expiresAt: formatter.string(from: grant.expiresAt),
                revoked: grant.revoked)
        }
    }

    @Sendable
    func revoke(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard
            let grantID = req.parameters.get("grantID", as: UUID.self),
            let grant = try await MCPGrant.find(grantID, on: req.db)
        else {
            throw Abort(.notFound)
        }
        guard user.isAdmin || grant.userID == user.id else {
            throw Abort(.forbidden)
        }
        grant.revoked = true
        try await grant.save(on: req.db)
        await AuditLogger.record(
            action: .mcpGrantRevoked, targetType: .user, targetID: grant.userID.uuidString,
            metadata: ["client_id": grant.clientID], on: req)
        return req.redirect(to: "/agents")
    }
}

struct AgentGrantRow: Encodable {
    let id: String
    let agentName: String
    let scope: String
    /// Owner username, populated only in the admin (all-grants) view.
    let owner: String?
    let createdAt: String
    let lastUsedAt: String?
    let expiresAt: String
    let revoked: Bool
}

struct ConnectedAgentsContext: Encodable {
    let currentUser: CurrentUserContext?
    let isAdmin: Bool
    let rows: [AgentGrantRow]
}
