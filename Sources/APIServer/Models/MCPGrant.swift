// APIServer/Models/MCPGrant.swift
//
// A durable OAuth authorization grant: the record that lets an agent keep
// working on a human's behalf for a term.  Backs refresh-token rotation and
// revocation — short-lived access tokens are minted from it, and revoking the
// grant (next PR) stops further refreshes.  Only the SHA-256 hash of the
// current refresh token is stored.
//
// Dormant in this PR: the model + migration land here; the /token refresh
// exchange + revocation follow in the next PR.

import Fluent
import Foundation
import Vapor

final class MCPGrant: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "oauth_grants"

    @ID(key: .id)
    var id: UUID?

    /// The human this grant acts on behalf of (the access token's subject).
    @Field(key: "user_id")
    var userID: UUID

    @Field(key: "client_id")
    var clientID: String

    /// Space-delimited granted scopes.
    @Field(key: "scope")
    var scope: String

    /// SHA-256 hex digest of the current (rotating) refresh token.
    @Field(key: "refresh_token_hash")
    var refreshTokenHash: String

    /// When the grant lapses (a term out); refresh fails past this.
    @Field(key: "expires_at")
    var expiresAt: Date

    @OptionalField(key: "last_used_at")
    var lastUsedAt: Date?

    /// Set true on explicit revocation; a revoked grant refreshes no further.
    @Field(key: "revoked")
    var revoked: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userID: UUID,
        clientID: String,
        scope: String,
        refreshTokenHash: String,
        expiresAt: Date,
        lastUsedAt: Date? = nil,
        revoked: Bool = false
    ) {
        self.id = id
        self.userID = userID
        self.clientID = clientID
        self.scope = scope
        self.refreshTokenHash = refreshTokenHash
        self.expiresAt = expiresAt
        self.lastUsedAt = lastUsedAt
        self.revoked = revoked
    }
}
