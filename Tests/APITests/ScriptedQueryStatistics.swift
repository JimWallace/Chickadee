// Tests/APITests/ScriptedQueryStatistics.swift
//
// The fixtures for `QueryStatistics` and the `get_query_stats` tool. The test
// database does not load pg_stat_statements, so the tests stand in for it in
// two ways, with no change to the database's settings:
//
// - `ScriptedCatalogDatabase` answers the two catalog questions (is the
//   library loaded, where is the extension) from a `CatalogScript`, and
//   records a CREATE EXTENSION statement instead of running it. Every other
//   statement goes to Postgres. `Application.useScriptedCatalog` makes it the
//   database that `req.db` returns, for code that reads the request.
// - `withQueryStatsSchema` makes a schema of the test's own that holds tables
//   shaped like the extension's two views. The reads name their schema, so
//   the real SQL runs against rows the test controls.

import Fluent
import Foundation
import NIOCore
import SQLKit
import Synchronization
import Testing
import VaporTesting

@testable import APIServer

// MARK: - Stats schema

/// Runs `body` with a schema of its own that holds tables shaped like the
/// extension's views, and drops the schema however the body ends.
func withQueryStatsSchema(
    _ app: Application, withInfoView: Bool = true,
    _ body: (any SQLDatabase, String) async throws -> Void
) async throws {
    let sql = try #require(app.db as? any SQLDatabase)
    let schema = "qstats_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12))"
    try await sql.raw("CREATE SCHEMA \(ident: schema)").run()
    var failure: (any Error)?
    do {
        try await sql.raw(
            """
            CREATE TABLE \(ident: schema).pg_stat_statements (
                dbid oid NOT NULL, queryid bigint NOT NULL, calls bigint NOT NULL,
                total_exec_time double precision NOT NULL, mean_exec_time double precision NOT NULL,
                max_exec_time double precision NOT NULL, rows bigint NOT NULL,
                shared_blks_hit bigint NOT NULL, shared_blks_read bigint NOT NULL, query text NOT NULL)
            """
        ).run()
        if withInfoView {
            try await sql.raw(
                "CREATE TABLE \(ident: schema).pg_stat_statements_info (stats_reset timestamptz NOT NULL)"
            ).run()
        }
        try await body(sql, schema)
    } catch {
        failure = error
    }
    try await sql.raw("DROP SCHEMA \(ident: schema) CASCADE").run()
    if let failure { throw failure }
}

struct QueryStatRow {
    let id: Int64
    let query: String
    var calls: Int64 = 1
    let total: Double
    var mean: Double = 1
    var hit: Int64 = 0
    var read: Int64 = 0
    var otherDatabase = false
}

func insertQueryStats(_ rows: [QueryStatRow], into schema: String, on sql: any SQLDatabase) async throws {
    for row in rows {
        let dbid =
            row.otherDatabase
            ? "0"
            : "(SELECT oid FROM pg_database WHERE datname = current_database())"
        try await sql.raw(
            """
            INSERT INTO \(ident: schema).pg_stat_statements
                (dbid, queryid, calls, total_exec_time, mean_exec_time, max_exec_time, rows,
                 shared_blks_hit, shared_blks_read, query)
            VALUES (\(unsafeRaw: dbid), \(bind: row.id), \(bind: row.calls), \(bind: row.total), \(bind: row.mean),
                    \(bind: row.total), \(bind: row.calls), \(bind: row.hit), \(bind: row.read),
                    \(bind: row.query))
            """
        ).run()
    }
}

// MARK: - Scripted catalog

/// The answers to the two catalog questions, and the statements the code
/// sent. Shared with the database wrapper, which a test cannot reach after
/// handing it over.
final class CatalogScript: Sendable {
    enum Create: Sendable {
        case succeeds
        case fails
        case failsButAnotherServerCreatesIt
    }

    enum CreateError: Error {
        case permissionDenied
    }

    private struct State {
        var extensionSchema: String?
        var statements: [String] = []
    }

    let libraries: String
    let create: Create
    private let state: Mutex<State>

    init(libraries: String, extensionSchema: String?, create: Create = .succeeds) {
        self.libraries = libraries
        self.create = create
        self.state = Mutex(State(extensionSchema: extensionSchema))
    }

    var statements: [String] { state.withLock { $0.statements } }
    var extensionSchema: String? { state.withLock { $0.extensionSchema } }

    func record(_ statement: String) {
        state.withLock { $0.statements.append(statement) }
    }

    /// Applies a CREATE EXTENSION and returns the error to fail it with, if any.
    func applyCreate() -> CreateError? {
        state.withLock { state in
            switch create {
            case .succeeds:
                state.extensionSchema = "public"
                return nil
            case .fails:
                return .permissionDenied
            case .failsButAnotherServerCreatesIt:
                state.extensionSchema = "public"
                return .permissionDenied
            }
        }
    }
}

/// The test database, except that it answers the two catalog questions from
/// a script and does not run CREATE EXTENSION.
struct ScriptedCatalogDatabase: Database, SQLDatabase {
    let fluent: any Database
    let sql: any SQLDatabase
    let script: CatalogScript

    // MARK: SQLDatabase

    var logger: Logger { sql.logger }
    var eventLoop: any EventLoop { sql.eventLoop }
    var dialect: any SQLDialect { sql.dialect }

    func execute(
        sql query: any SQLExpression, _ onRow: @escaping @Sendable (any SQLRow) -> Void
    )
        -> EventLoopFuture<Void>
    {
        let text = serialize(query).sql
        script.record(text)
        if text.contains("current_setting('shared_preload_libraries')") {
            let answer: SQLQueryString = "SELECT \(bind: script.libraries)::text AS libraries"
            return sql.execute(sql: answer, onRow)
        }
        if text.contains("FROM pg_extension") {
            let answer: SQLQueryString =
                if let schema = script.extensionSchema {
                    "SELECT \(bind: schema)::text AS schema_name"
                } else {
                    "SELECT 'none'::text AS schema_name WHERE false"
                }
            return sql.execute(sql: answer, onRow)
        }
        if text.hasPrefix("CREATE EXTENSION") {
            if let error = script.applyCreate() {
                return eventLoop.makeFailedFuture(error)
            }
            return eventLoop.makeSucceededVoidFuture()
        }
        return sql.execute(sql: query, onRow)
    }

    // MARK: Database

    var context: DatabaseContext { fluent.context }
    var inTransaction: Bool { fluent.inTransaction }

    func execute(
        query: DatabaseQuery, onOutput: @escaping @Sendable (any DatabaseOutput) -> Void
    )
        -> EventLoopFuture<Void>
    {
        fluent.execute(query: query, onOutput: onOutput)
    }

    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> {
        fluent.execute(schema: schema)
    }

    func execute(enum: DatabaseEnum) -> EventLoopFuture<Void> {
        fluent.execute(enum: `enum`)
    }

    func transaction<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        fluent.transaction(closure)
    }

    func withConnection<T>(
        _ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>
    )
        -> EventLoopFuture<T>
    {
        fluent.withConnection(closure)
    }
}

// MARK: - The request's database

extension Application {
    /// Makes `ScriptedCatalogDatabase` over this app's database the default,
    /// so that `req.db` answers the catalog questions from `script`.
    func useScriptedCatalog(_ script: CatalogScript) throws {
        let base = db
        let configuration = ScriptedCatalogConfiguration(
            base: base, sql: try #require(base as? any SQLDatabase), script: script)
        databases.use(configuration, as: .scriptedCatalog, isDefault: true)
    }
}

extension DatabaseID {
    static let scriptedCatalog = DatabaseID(string: "scripted-catalog")
}

private struct ScriptedCatalogConfiguration: DatabaseConfiguration {
    var middleware: [any AnyModelMiddleware] = []
    let base: any Database
    let sql: any SQLDatabase
    let script: CatalogScript

    func makeDriver(for databases: Databases) -> any DatabaseDriver {
        Driver(base: base, sql: sql, script: script)
    }

    struct Driver: DatabaseDriver {
        let base: any Database
        let sql: any SQLDatabase
        let script: CatalogScript

        func makeDatabase(with context: DatabaseContext) -> any Database {
            ScriptedCatalogDatabase(fluent: base, sql: sql, script: script)
        }

        func shutdown() {}
    }
}
