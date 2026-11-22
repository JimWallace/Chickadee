// APIServer/Services/CollationVersionMismatchRule.swift
//
// The `collationVersionMismatch` health rule: the database's default collation
// now comes from a different version of the C library (libc provider) or ICU
// than the one its indexes were built with. Postgres records the version when
// the database is created (`pg_database.datcollversion`) and reports the
// running library's version through
// `pg_database_collation_actual_version`. When they differ, a B-tree index on
// a text column may hold its keys in an order the server no longer agrees
// with: lookups miss rows and a unique index can admit a duplicate.
//
// A major upgrade by dump and restore rebuilds every index, so it cannot cause
// this. A new image of the SAME major can: the db service runs a floating tag
// (`postgres:18`, in `docker-compose.db.yml` on an upgraded host), and a new
// Debian base under that tag brings a new glibc. Postgres logs a warning on
// each connection, which no one reads; this rule makes it an alert.
//
// The builtin provider and the C and POSIX locales have no library version,
// so both values are NULL there and the rule stays green.

import Fluent
import SQLKit
import Vapor

/// Decides the rule from the version the database recorded and the version
/// the running library reports. Either one nil means there is nothing to
/// compare.
func decideCollationVersionMismatch(recorded: String?, actual: String?) -> RuleEvaluation {
    guard let recorded, let actual, recorded != actual else { return .ok }
    return RuleEvaluation(
        isFiring: true,
        summary:
            "The database's collation library changed from version \(recorded) to \(actual), so indexes on "
            + "text may be out of order. Run REINDEX DATABASE, then ALTER DATABASE … REFRESH COLLATION VERSION.",
        details: ["recorded_version": recorded, "actual_version": actual])
}

/// Reads both versions for the current database and decides the rule.
func evaluateCollationVersionMismatch(on application: Application) async throws -> RuleEvaluation {
    guard let sql = application.db as? (any SQLDatabase) else {
        throw AppError.internalFailure(reason: "The collation version read needs a SQL database.")
    }
    let row = try await sql.raw(
        """
        SELECT datcollversion AS recorded, pg_database_collation_actual_version(oid) AS actual
        FROM pg_database WHERE datname = current_database()
        """
    ).first()
    guard let row else { return .ok }
    return decideCollationVersionMismatch(
        recorded: try row.decode(column: "recorded", as: String?.self),
        actual: try row.decode(column: "actual", as: String?.self))
}
