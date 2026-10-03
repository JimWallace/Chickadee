// Tests/APITests/WriteLockedTransactionTests.swift
//
// A read-then-write SQLite transaction against a competing writer (#1919).
//
// Each test builds its own WAL-mode SQLite file and opens a second, raw
// connection to the same file, so it runs the same on the SQLite and Postgres
// lanes. The second connection acts at the exact moment that fails a
// read-then-write transaction: it holds the write lock while the transaction
// reads (the case that lost a browser result in CI), or it commits after the
// transaction read and before it wrote. No timing has to line up for the
// failure to appear.

import FluentSQLiteDriver
import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOPosix
import SQLKit
import Testing

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2))) struct WriteLockedTransactionTests {
    private static func withWALDatabase(_ body: (Fixture) async throws -> Void) async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-write-lock-\(UUID().uuidString).sqlite").path
        let pool = NIOThreadPool(numberOfThreads: 2)
        let competitorPool = NIOThreadPool(numberOfThreads: 1)
        pool.start()
        competitorPool.start()
        let databases = Databases(threadPool: pool, on: MultiThreadedEventLoopGroup.singleton)
        databases.use(.sqlite(SQLiteConfiguration(storage: .file(path: path))), as: .sqlite)
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        do {
            let db = try #require(
                databases.database(
                    .sqlite, logger: Logger(label: "write-locked-transaction-tests"),
                    on: MultiThreadedEventLoopGroup.singleton.any()))
            let sql = try #require(db as? any SQLDatabase)
            try await sql.raw("PRAGMA journal_mode = WAL").run()
            try await sql.raw("CREATE TABLE attempts (id INTEGER PRIMARY KEY, n INTEGER NOT NULL)").run()
            try await body(Fixture(db: db, path: path, competitorPool: competitorPool))
        } catch {
            await databases.shutdownAsync()
            try await pool.shutdownGracefully()
            try await competitorPool.shutdownGracefully()
            throw error
        }
        await databases.shutdownAsync()
        try await pool.shutdownGracefully()
        try await competitorPool.shutdownGracefully()
    }

    /// The read the attempt-number transaction makes before it writes.
    private static func highestN(on db: any Database) async throws -> Int {
        let sql = try #require(db as? any SQLDatabase)
        let row = try await sql.raw("SELECT COALESCE(MAX(n), 0) AS top FROM attempts").first()
        return try #require(row).decode(column: "top", as: Int.self)
    }

    private static func insert(_ n: Int, on db: any Database) async throws {
        let sql = try #require(db as? any SQLDatabase)
        try await sql.raw("INSERT INTO attempts (n) VALUES (\(bind: n))").run()
    }

    /// Another connection commits one row, as a concurrent request would.
    private static func competingInsert(_ fixture: Fixture) async throws {
        let connection = try await SQLiteConnection.open(
            storage: .file(path: fixture.path), threadPool: fixture.competitorPool,
            on: MultiThreadedEventLoopGroup.singleton.any())
        do {
            try await connection.query("INSERT INTO attempts (n) VALUES (99)", []) { _ in }
        } catch {
            try? await connection.close()
            throw error
        }
        try await connection.close()
    }

    /// Another connection opens a write transaction and inserts a row, and
    /// holds the write lock until the caller commits it.
    private static func holdWriteLock(_ fixture: Fixture) async throws -> SQLiteConnection {
        let connection = try await SQLiteConnection.open(
            storage: .file(path: fixture.path), threadPool: fixture.competitorPool,
            on: MultiThreadedEventLoopGroup.singleton.any())
        try await connection.query("BEGIN IMMEDIATE TRANSACTION", []) { _ in }
        try await connection.query("INSERT INTO attempts (n) VALUES (99)", []) { _ in }
        return connection
    }

    private static func commitAndClose(_ connection: SQLiteConnection) async throws {
        try await connection.query("COMMIT TRANSACTION", []) { _ in }
        try await connection.close()
    }

    private static func storedNs(on db: any Database) async throws -> [Int] {
        let sql = try #require(db as? any SQLDatabase)
        return try await sql.raw("SELECT n FROM attempts ORDER BY id").all()
            .map { try $0.decode(column: "n", as: Int.self) }
    }

    /// The control for the case CI hit: Fluent's own transaction is deferred,
    /// so once it has read it cannot wait for a write lock that another
    /// connection holds, and its write fails at once. If this ever passes,
    /// SQLite or the driver changed, and the helper may no longer be needed.
    @Test func aDeferredTransactionFailsWhileAnotherConnectionHoldsTheWriteLock() async throws {
        try await Self.withWALDatabase { fixture throws in
            let holder = try await Self.holdWriteLock(fixture)
            let error = await #expect(throws: (any Error).self) {
                try await fixture.db.transaction { tx in
                    let top = try await Self.highestN(on: tx)
                    try await Self.insert(top + 1, on: tx)
                }
            }
            #expect(String(describing: error).lowercased().contains("locked"))
            try await Self.commitAndClose(holder)
            #expect(try await Self.storedNs(on: fixture.db) == [99])
        }
    }

    /// The fix for that case: the transaction waits for the write lock before
    /// it reads, so it reads the other connection's committed row and numbers
    /// after it.
    @Test func aWriteLockedTransactionWaitsForAnotherConnectionsWriteLock() async throws {
        try await Self.withWALDatabase { fixture throws in
            let holder = try await Self.holdWriteLock(fixture)
            let transaction = Task {
                try await withWriteLockedTransaction(on: fixture.db) { tx in
                    let top = try await Self.highestN(on: tx)
                    try await Self.insert(top + 1, on: tx)
                }
            }
            // Long enough for the transaction to reach the lock and wait.
            try await Task.sleep(for: .milliseconds(300))
            try await Self.commitAndClose(holder)
            try await transaction.value
            #expect(try await Self.storedNs(on: fixture.db) == [99, 100])
        }
    }

    /// The control for the other case: a commit by another connection between
    /// the read and the write makes the read stale, and the write fails at once.
    @Test func aDeferredTransactionFailsWhenAnotherConnectionCommitsBetweenItsReadAndWrite() async throws {
        try await Self.withWALDatabase { fixture throws in
            let error = await #expect(throws: (any Error).self) {
                try await fixture.db.transaction { tx in
                    let top = try await Self.highestN(on: tx)
                    try await Self.competingInsert(fixture)
                    try await Self.insert(top + 1, on: tx)
                }
            }
            #expect(String(describing: error).lowercased().contains("locked"))
            #expect(try await Self.storedNs(on: fixture.db) == [99])
        }
    }

    /// The fix for that case: the transaction holds the write lock before it
    /// reads, so the competing writer waits until it commits, and both rows are
    /// stored.
    @Test func aWriteLockedTransactionMakesTheOtherWriterWait() async throws {
        try await Self.withWALDatabase { fixture throws in
            let order = NIOLockedValueBox<[String]>([])
            let competitor = NIOLockedValueBox<Task<Void, any Error>?>(nil)
            try await withWriteLockedTransaction(on: fixture.db) { tx in
                let top = try await Self.highestN(on: tx)
                competitor.withLockedValue { task in
                    task = Task {
                        try await Self.competingInsert(fixture)
                        order.withLockedValue { $0.append("competitor") }
                    }
                }
                // Long enough for the competitor to reach the lock and wait.
                try await Task.sleep(for: .milliseconds(300))
                try await Self.insert(top + 1, on: tx)
                order.withLockedValue { $0.append("transaction") }
            }
            try await #require(competitor.withLockedValue { $0 }).value
            #expect(order.withLockedValue { $0 } == ["transaction", "competitor"])
            #expect(try await Self.storedNs(on: fixture.db) == [1, 99])
        }
    }

    /// Inside a caller's transaction the helper joins it instead of opening a
    /// second one, which SQLite would refuse.
    @Test func insideATransactionTheHelperJoinsIt() async throws {
        try await Self.withWALDatabase { fixture throws in
            try await fixture.db.transaction { tx in
                try await withWriteLockedTransaction(on: tx) { inner in
                    try await Self.insert(1, on: inner)
                }
                try await Self.insert(2, on: tx)
            }
            #expect(try await Self.storedNs(on: fixture.db) == [1, 2])
        }
    }

    /// A body that throws rolls back what it wrote, and the connection it ran
    /// on is usable afterwards.
    @Test func aThrowingBodyRollsBack() async throws {
        try await Self.withWALDatabase { fixture throws in
            await #expect(throws: CancellationError.self) {
                try await withWriteLockedTransaction(on: fixture.db) { tx in
                    try await Self.insert(1, on: tx)
                    throw CancellationError()
                }
            }
            #expect(try await Self.storedNs(on: fixture.db).isEmpty)
            try await withWriteLockedTransaction(on: fixture.db) { tx in
                try await Self.insert(2, on: tx)
            }
            #expect(try await Self.storedNs(on: fixture.db) == [2])
        }
    }

    /// A WAL-mode SQLite file with one table, the Fluent database over it, and
    /// a thread pool for the competing connection. The competing writer gets
    /// its own pool, because while it waits for the write lock it holds a
    /// thread, and the transaction it waits on needs a thread to commit.
    private struct Fixture {
        let db: any Database
        let path: String
        let competitorPool: NIOThreadPool
    }
}
