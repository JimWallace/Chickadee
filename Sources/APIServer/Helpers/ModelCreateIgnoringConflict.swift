// APIServer/Helpers/ModelCreateIgnoringConflict.swift
//
// "First insert wins" for rows that two results can try to create at once:
// a badge, a leaderboard entry, a coverage item, a match row (#2300).

import Fluent

extension Model {
    /// Creates this row, and does nothing when the database refuses it with a
    /// constraint failure: another request inserted the same row first.
    ///
    /// Every other error is thrown. These inserts run inside
    /// `withTransientDatabaseLockRetry`, and a `try?` here used to swallow the
    /// stale-snapshot lock error that retry exists for, so the row was lost
    /// with no log.
    func createIgnoringConflict(on db: Database) async throws {
        do {
            try await create(on: db)
        } catch  where isInsertConflict(error) {
            return
        }
    }
}

/// Whether `error` is the database refusing an insert because the row, or a
/// row it must agree with, already decided the outcome.
func isInsertConflict(_ error: any Error) -> Bool {
    (error as? any DatabaseError)?.isConstraintFailure == true
}
