import Fluent
import SQLKit

/// Shared login-rate-limit events (#1154): per-IP window counts and
/// per-username failure counts move from process-local memory to the
/// database so brute-force protection holds across a multi-process
/// deployment. The composite index backs every query the service issues
/// (count/prune by (scope, key) with an `occurred_at` bound).
struct CreateLoginAttempts: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(LoginAttempt.schema)
            .id()
            .field("scope", .string, .required)
            .field("attempt_key", .string, .required)
            .field("occurred_at", .datetime, .required)
            .create()

        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_login_attempts_scope_key_time "
                    + "ON login_attempts(scope, attempt_key, occurred_at)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema(LoginAttempt.schema).delete()
    }
}
