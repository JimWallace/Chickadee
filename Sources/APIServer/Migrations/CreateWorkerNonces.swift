import Fluent
import SQLKit

/// Replay-protection nonces for worker HMAC auth (#1154). The PRIMARY KEY on
/// `nonce_key` makes first-seen an atomic INSERT across every server process
/// sharing the database. The `expires_at` index backs the opportunistic
/// purge (`DELETE WHERE expires_at <= now`).
struct CreateWorkerNonces: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(WorkerNonce.schema)
            .field("nonce_key", .string, .identifier(auto: false))
            .field("expires_at", .datetime, .required)
            .create()

        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_worker_nonces_expires_at ON worker_nonces(expires_at)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema(WorkerNonce.schema).delete()
    }
}
