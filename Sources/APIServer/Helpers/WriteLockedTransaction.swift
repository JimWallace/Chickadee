// APIServer/Helpers/WriteLockedTransaction.swift
//
// A transaction that holds the write lock from its first statement (#1919).
//
// Fluent opens a SQLite transaction with a plain `BEGIN TRANSACTION`, which is
// deferred: the transaction takes a read snapshot at its first read and asks
// for the write lock only at its first write. sqlite-nio installs a busy
// handler that retries a contended lock for as long as it takes, but SQLite
// calls it only for a transaction that has not read yet. A transaction that
// has read cannot wait for the write lock, so its first write fails at once
// with "database is locked" in two cases:
//
//   - another connection holds the write lock (SQLITE_BUSY). This is the case
//     that lost a browser result in CI;
//   - another connection committed after the read (SQLITE_BUSY_SNAPSHOT).
//
// `BEGIN IMMEDIATE` takes the write lock before the first read, while the
// transaction has read nothing, so the busy handler waits for a competing
// writer instead. Once it holds the lock, no other connection can write, so
// its snapshot cannot go stale.

import Fluent
import SQLKit

/// Runs `body` in a transaction that holds the write lock before it reads.
///
/// On SQLite the transaction is opened with `BEGIN IMMEDIATE`. On Postgres, and
/// for a caller that is already inside a transaction, this is an ordinary
/// `transaction`. Use it for a transaction that reads and then writes based on
/// what it read; a transaction that writes first does not need it.
///
/// On SQLite, `body` runs on a connection that Fluent does not know is inside a
/// transaction, so `body` must not open a transaction of its own.
func withWriteLockedTransaction<T: Sendable>(
    on db: any Database,
    _ body: @escaping @Sendable (any Database) async throws -> T
) async throws -> T {
    guard !db.inTransaction, let sql = db as? any SQLDatabase, sql.dialect.name == "sqlite" else {
        return try await db.transaction(body)
    }
    return try await db.withConnection { connection in
        guard let sqlConnection = connection as? any SQLDatabase else {
            return try await connection.transaction(body)
        }
        try await sqlConnection.raw("BEGIN IMMEDIATE TRANSACTION").run()
        do {
            let result = try await body(connection)
            try await sqlConnection.raw("COMMIT TRANSACTION").run()
            return result
        } catch {
            try? await sqlConnection.raw("ROLLBACK TRANSACTION").run()
            throw error
        }
    }
}
