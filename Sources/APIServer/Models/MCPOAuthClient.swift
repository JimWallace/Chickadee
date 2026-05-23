// APIServer/Models/MCPOAuthClient.swift
//
// A registered OAuth client (an "agent") for the MCP authorization server.
// Phase 2 issues access tokens to a *human* (the token subject), with the
// client recorded separately so agent activity is auditable distinct from
// direct web actions.  Clients are public (PKCE, no secret) in v1 — created by
// an admin or via Dynamic Client Registration (a later PR).
//
// Dormant in this PR: the model + migration land here; the /authorize + /token
// flow that consumes them follows in the next PR.

import Fluent
import Foundation
import Vapor

final class MCPOAuthClient: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "oauth_clients"

    @ID(key: .id)
    var id: UUID?

    /// Public, stable client identifier surfaced to the agent.
    @Field(key: "client_id")
    var clientID: String

    /// Human-readable agent/application name, shown on the consent screen.
    @Field(key: "name")
    var name: String

    /// Newline-delimited list of allowed redirect URIs (exact-match at
    /// `/authorize`).  Stored as one string so the schema is identical on
    /// SQLite and Postgres; use `redirectURIs` for the parsed list.
    @Field(key: "redirect_uris")
    var redirectURIsRaw: String

    /// True for public clients (PKCE, no client secret) — the only kind in v1.
    @Field(key: "is_public")
    var isPublic: Bool

    /// The admin who registered the client, or nil when self-registered (DCR).
    @OptionalField(key: "created_by")
    var createdByUserID: UUID?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        clientID: String,
        name: String,
        redirectURIs: [String],
        isPublic: Bool = true,
        createdByUserID: UUID? = nil
    ) {
        self.id = id
        self.clientID = clientID
        self.name = name
        self.redirectURIsRaw = MCPOAuthClient.joinRedirectURIs(redirectURIs)
        self.isPublic = isPublic
        self.createdByUserID = createdByUserID
    }

    /// The registered redirect URIs, parsed from the stored newline-delimited
    /// string (blank lines dropped).
    var redirectURIs: [String] {
        get {
            redirectURIsRaw
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        set { redirectURIsRaw = MCPOAuthClient.joinRedirectURIs(newValue) }
    }

    private static func joinRedirectURIs(_ uris: [String]) -> String {
        uris.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
