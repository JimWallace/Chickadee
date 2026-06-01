// APIServer/Migrations/AddGrantPreviousRefreshTokenHashIndex.swift
//
// Adds an index on `oauth_grants.previous_refresh_token_hash`.  The refresh
// rotation theft-detection lookup (a token matching an already-rotated-away
// hash revokes the grant) and the `POST /oauth/revoke` OR-filter both query
// this column on every refresh / revoke.  `refresh_token_hash` is already
// indexed by its UNIQUE constraint, but the previous-hash column was added
// (in `AddPreviousRefreshTokenHashToGrants`) without one, so those hot-path
// queries degrade to a full table scan as long-lived grants accumulate.
//
// A separate migration (rather than folding the index into the canonical
// `CreateMCPGrants` / `CreateHotPathIndexes`) so existing production databases
// — which already have those migrations marked applied — actually create it.
// `IF NOT EXISTS` keeps it safe on fresh deploys.

import Fluent
import SQLKit

struct AddGrantPreviousRefreshTokenHashIndex: ChickadeeMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_oauth_grants_previous_refresh_token_hash "
                + "ON oauth_grants(previous_refresh_token_hash)"
        ).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS idx_oauth_grants_previous_refresh_token_hash").run()
    }
}
