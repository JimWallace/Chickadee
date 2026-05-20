// APIServer/Migrations/AddUrlTokenToUsers.swift
//
// Adds the per-user `url_token` column used by instructor-facing
// per-student URLs (#556).  Replaces the previous `:username` URL
// segments with an opaque 8-character lowercase alphanumeric token so
// usernames stop leaking into nginx access logs, browser history, and
// Referer headers.
//
// Migration shape:
//   1. Add `url_token` as a nullable column (Fluent / SQLite can't add
//      NOT NULL post-hoc cleanly, and a nullable column is enough — the
//      model invariant is that every row carries a token, enforced by
//      the init default plus this migration's backfill).
//   2. Backfill: every existing user gets a unique token.  Collision
//      retries cover the (vanishingly unlikely) case where two rows
//      hash to the same 8-char token.
//   3. Create a unique index so future writes can't violate the
//      invariant.

import Fluent
import SQLKit
import Vapor

struct AddUrlTokenToUsers: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("users")
            .field("url_token", .string)
            .update()

        // Backfill existing users.
        let users = try await APIUser.query(on: database).all()
        for user in users where user.urlToken == nil {
            user.urlToken = try await uniqueURLToken(on: database)
            try await user.save(on: database)
        }

        // Enforce uniqueness from here on.  Partial index so the
        // (transient) NULLs above don't violate uniqueness; once every
        // row is backfilled the partial clause matches everything.
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_users_url_token
                ON users(url_token)
                WHERE url_token IS NOT NULL
                """
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_users_url_token").run()
        }
        try await database.schema("users")
            .deleteField("url_token")
            .update()
    }

    /// Generates a candidate token and retries until one is unused.  At
    /// 36^8 ≈ 2.8 × 10^12 combinations the expected number of retries
    /// stays at 0 for any realistic user count, but the loop is here so
    /// a future shrink to a shorter token (or a partial backfill that
    /// races with new sign-ups) stays safe.
    private func uniqueURLToken(on database: Database) async throws -> String {
        for _ in 0..<16 {
            let candidate = APIUser.generateURLToken()
            let collision =
                try await APIUser.query(on: database)
                .filter(\.$urlToken == candidate)
                .count() > 0
            if !collision {
                return candidate
            }
        }
        throw Abort(.internalServerError, reason: "Could not generate a unique url_token after 16 attempts")
    }
}
