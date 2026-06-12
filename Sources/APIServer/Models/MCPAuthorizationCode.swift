// APIServer/Models/MCPAuthorizationCode.swift
//
// A short-lived OAuth 2.1 authorization code (PKCE).  Issued by /authorize
// after the human consents, exchanged once at /token for an access + refresh
// token.  Only the SHA-256 hash of the code is stored; the plaintext lives only
// in the redirect to the client.
//
// Dormant in this PR: the model + migration land here; /authorize + /token
// follow in the next PR.

import Fluent
import Foundation
import Vapor

final class MCPAuthorizationCode: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "oauth_authorization_codes"

    @ID(key: .id)
    var id: UUID?

    /// SHA-256 hex digest of the issued code (the plaintext is never stored).
    @Field(key: "code_hash")
    var codeHash: String

    @Field(key: "client_id")
    var clientID: String

    /// The consenting human; the eventual access token's subject.
    @Field(key: "user_id")
    var userID: UUID

    @Field(key: "redirect_uri")
    var redirectURI: String

    /// PKCE code challenge + method ("S256"); verified at /token.
    @Field(key: "code_challenge")
    var codeChallenge: String

    @Field(key: "code_challenge_method")
    var codeChallengeMethod: String

    /// Space-delimited granted scopes (e.g. "content:read content:write").
    @Field(key: "scope")
    var scope: String

    @Field(key: "expires_at")
    var expiresAt: Date

    /// Set true the moment the code is redeemed, so a replay is rejected.
    @Field(key: "consumed")
    var consumed: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        codeHash: String,
        clientID: String,
        userID: UUID,
        redirectURI: String,
        codeChallenge: String,
        codeChallengeMethod: String,
        scope: String,
        expiresAt: Date,
        consumed: Bool = false
    ) {
        self.id = id
        self.codeHash = codeHash
        self.clientID = clientID
        self.userID = userID
        self.redirectURI = redirectURI
        self.codeChallenge = codeChallenge
        self.codeChallengeMethod = codeChallengeMethod
        self.scope = scope
        self.expiresAt = expiresAt
        self.consumed = consumed
    }
}
