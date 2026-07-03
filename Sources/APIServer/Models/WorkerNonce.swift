import Fluent
import Foundation
import Vapor

/// One consumed worker-HMAC nonce. The PRIMARY KEY on `nonce_key` is the
/// replay guard: first-seen is an atomic INSERT, and a unique violation means
/// the (workerID, nonce) pair was already consumed — by ANY server process
/// sharing this database, which is the property the old in-memory
/// `WorkerNonceStore` could not provide behind a load balancer (2026-07
/// audit, #1154). Rows expire after the signing TTL and are purged
/// opportunistically by the middleware.
final class WorkerNonce: Model, @unchecked Sendable {
    // @unchecked Sendable: written once at creation, never mutated after.
    static let schema = "worker_nonces"

    @ID(custom: "nonce_key", generatedBy: .user)
    var id: String?

    @Field(key: "expires_at")
    var expiresAt: Date

    init() {}

    init(nonceKey: String, expiresAt: Date) {
        self.id = nonceKey
        self.expiresAt = expiresAt
    }
}
