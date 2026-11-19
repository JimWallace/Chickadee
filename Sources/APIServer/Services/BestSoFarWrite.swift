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
// Here the comparison is inside the UPDATE, so the database decides it
// atomically, and the order the results land in no longer matters.

import Fluent

/// Writes a best-so-far row without a read-modify-write race.
///
/// - `raise`: one conditional UPDATE that changes the row only where the new
///   value is strictly better. Atomic on its own.
/// - `exists`: whether the row is there.
/// - `insert`: creates the row with the new value.
///
/// The existence check comes first so that `raise` runs against a row that
/// already exists. With no row, the insert either lands (this value is the
/// first) or is refused by a constraint, and then the conditional update
/// settles which value is better. A refusal is usually the unique key (a
/// concurrent first result); a foreign key (the user was just deleted) also
/// lands there, and the update then finds nothing, which is the right answer.
///
/// What this does not cover: a row DELETED between the check and the update
/// (a class-record recompute that finds no winner, or an admin deleting the
/// user). The update then matches nothing and this value is dropped without an
/// error. The window is one round trip, and the next result, or the
/// leaderboard's repair, writes it again.
///
/// Not for use inside a transaction: on Postgres a refused insert aborts the
/// transaction, so the update after it would fail.
func writeBestSoFar(
    raise: () async throws -> Void,
    exists: () async throws -> Bool,
    insert: () async throws -> Void
) async throws {
    if try await exists() {
        try await raise()
        return
    }
    do {
        try await insert()
    } catch  where isInsertConflict(error) {
        try await raise()
    }
}
