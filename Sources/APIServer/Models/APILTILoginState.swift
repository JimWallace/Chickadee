// APIServer/Models/APILTILoginState.swift
//
// One LTI 1.3 third-party login in flight (docs/lti-1-3.md "Launch"). The
// login route writes a row; the launch route consumes it once. Only a hash
// of the `state` value is stored, so a database read cannot replay a login;
// the nonce is stored as sent, because the launch compares it to the
// `nonce` claim the platform signed.

import Fluent
import Vapor

final class APILTILoginState: Model, @unchecked Sendable {
    // @unchecked Sendable: only mutated within a request/DB context before save.
    static let schema = "lti_login_states"

    /// Five minutes: the platform redirects back within seconds, and a short
    /// window bounds how long a leaked `state` value is worth anything.
    static let lifetime: TimeInterval = 300

    @ID(key: .id)
    var id: UUID?

    /// SHA-256 (base64url) of the `state` value.
    @Field(key: "state_hash")
    var stateHash: String

    @Field(key: "nonce")
    var nonce: String

    @Field(key: "platform_id")
    var platformID: UUID

    @Field(key: "expires_at")
    var expiresAt: Date

    /// Flipped once, atomically, by the launch that uses this row.
    @Field(key: "consumed")
    var consumed: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(stateHash: String, nonce: String, platformID: UUID, expiresAt: Date) {
        self.stateHash = stateHash
        self.nonce = nonce
        self.platformID = platformID
        self.expiresAt = expiresAt
        self.consumed = false
    }
}
