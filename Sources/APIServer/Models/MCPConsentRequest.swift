// APIServer/Models/MCPConsentRequest.swift
//
// A short-lived, single-use consent request for the browser OAuth flow.  It is
// minted at `GET /oauth/authorize` (when a logged-in instructor is shown the
// consent screen) and redeemed once at `POST /oauth/authorize`.
//
// Why it exists: the consent POST runs in a cross-site browser context (the
// Claude connector opens the flow in a popup whose POST is treated as
// cross-site).  Safari/ITP — and increasingly every browser's third-party
// cookie policy — will not send the session cookie on that POST, so neither the
// session-bound CSRF token nor the authenticated user survive the hop.  This
// record carries both *without* a cookie: the consenting user's identity is
// frozen here at consent-render time, and the unguessable single-use token
// (delivered only into the same-origin consent page, so an attacker can't read
// it) is the CSRF defense.  Only the SHA-256 hash of the token is stored.

import Fluent
import Foundation
import Vapor

final class MCPConsentRequest: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "oauth_consent_requests"

    @ID(key: .id)
    var id: UUID?

    /// SHA-256 hex digest of the issued consent token (the plaintext lives only
    /// in the rendered consent form).
    @Field(key: "token_hash")
    var tokenHash: String

    /// The consenting human, captured from the authenticated session at GET
    /// time.  The POST trusts this rather than re-reading the (possibly absent)
    /// session, so identity survives a cookie-less cross-site submit.
    @Field(key: "user_id")
    var userID: UUID

    @Field(key: "client_id")
    var clientID: String

    @Field(key: "redirect_uri")
    var redirectURI: String

    /// Space-delimited resolved scopes, already clamped to the mode ceiling.
    @Field(key: "scope")
    var scope: String

    /// OAuth `state` (empty string when the client omitted it).
    @Field(key: "state")
    var state: String

    @Field(key: "code_challenge")
    var codeChallenge: String

    @Field(key: "code_challenge_method")
    var codeChallengeMethod: String

    @Field(key: "expires_at")
    var expiresAt: Date

    /// Set true the moment the request is redeemed, so a replay is rejected.
    @Field(key: "consumed")
    var consumed: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        tokenHash: String,
        userID: UUID,
        clientID: String,
        redirectURI: String,
        scope: String,
        state: String,
        codeChallenge: String,
        codeChallengeMethod: String,
        expiresAt: Date,
        consumed: Bool = false
    ) {
        self.id = id
        self.tokenHash = tokenHash
        self.userID = userID
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scope = scope
        self.state = state
        self.codeChallenge = codeChallenge
        self.codeChallengeMethod = codeChallengeMethod
        self.expiresAt = expiresAt
        self.consumed = consumed
    }
}
