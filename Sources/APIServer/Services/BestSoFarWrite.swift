// APIServer/Services/BestSoFarWrite.swift
//
// One write shape for a row that only ever moves to a better value: the
// leaderboard rows and the ranked class records.
//
// They used to read the row, compare in Swift and write it back. Two results
// landing at once both read the old value, and the later write could replace
// the better one: a student's best fell, or a record named the wrong student.
// A browser-graded class activity makes that likely, because 150 students post
// their results inside the same few seconds and each request writes its own.
//
// Here the whole write is one `INSERT … ON CONFLICT … DO UPDATE … WHERE`
// statement: the database inserts the first value, and replaces a stored one
// only where the new value is strictly better, atomically. The order the
// results land in does not matter, and no existence check or retry is needed.

import Fluent
import Foundation
import SQLKit

/// Writes a best-so-far row without a read-modify-write race.
///
/// - `table`, `columns`, `values`: the row to insert. The first column is the
///   primary key, which a stored row keeps.
/// - `key`: the columns of the unique key that names the row.
/// - `replacing`: the columns a better value overwrites.
/// - `isBetter`: the condition, over the stored row (`table`) and the new one
///   (`SQLExcludedColumn`), under which the stored row is replaced. A stored
///   NULL compares false, so a row with no value never moves.
///
/// A foreign key refusal (the student or the setup was deleted meanwhile)
/// drops the value without an error, as before. On Postgres that refusal
/// aborts a surrounding transaction, so this is still not for use inside one.
func writeBestSoFar(
    into table: String,
    columns: [String],
    values: [any Encodable & Sendable],
    key: [String],
    replacing: [String],
    whereBetter isBetter: any SQLExpression,
    on db: any Database
) async throws {
    guard let sql = db as? (any SQLDatabase) else {
        throw AppError.internalFailure(reason: "The best-so-far write needs a SQL database.")
    }
    do {
        try await sql.insert(into: table)
            .columns(columns)
            .values(values.map { SQLBind($0) })
            .onConflict(with: key) { conflict in
                replacing.reduce(conflict) { $0.set(excludedValueOf: $1) }.where(isBetter)
            }
            .run()
    } catch  where isInsertConflict(error) {
        return
    }
}

/// `stored.column < new.column` (or `>`), for `writeBestSoFar`'s condition.
func newValueIsBetter(_ column: String, in table: String, higherWins: Bool) -> any SQLExpression {
    SQLBinaryExpression(
        SQLColumn(column, table: table), higherWins ? .lessThan : .greaterThan, SQLExcludedColumn(column))
}
