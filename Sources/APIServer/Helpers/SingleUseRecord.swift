// APIServer/Helpers/SingleUseRecord.swift
//
// The one single-use primitive behind every "consume this row exactly once"
// rule: OAuth authorization codes and consent tokens, LTI login states and
// deep-link tickets. Each table carries a hash column and a `consumed` flag,
// and a caller must win the burn BEFORE it reads anything else from the row.
// It lived on MCPOAuthRoutes until the LTI flows became its third and fourth
// callers (#1650).

import Fluent
import SQLKit

enum SingleUseRecord {
    /// Atomically flips the `consumed` flag from false to true on the row
    /// whose `hashColumn` equals `hash`, and returns true only when THIS call
    /// won the flip. One conditional `UPDATE … WHERE consumed = false
    /// RETURNING` statement is atomic on both SQLite (WAL) and Postgres, so
    /// two concurrent submits of the same code, token or ticket can never both
    /// win, which closes the replay race a read-check-then-save leaves open.
    /// `table` and `hashColumn` are compile-time schema constants (no
    /// injection surface); only the hash is bound.
    static func burn(on db: Database, table: String, hashColumn: String, hash: String) async throws -> Bool {
        guard let sql = db as? SQLDatabase else { return true }
        let rows = try await sql.raw(
            "UPDATE \(unsafeRaw: table) SET consumed = true WHERE \(unsafeRaw: hashColumn) = \(bind: hash) AND consumed = false RETURNING id"
        ).all()
        return !rows.isEmpty
    }
}
