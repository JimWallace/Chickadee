// APIServer/Diagnostics/QueryStatistics.swift
//
// Per-statement database timing from the Postgres `pg_stat_statements`
// extension, for the admin MCP tool `get_query_stats`.
//
// The extension needs two steps. The operator loads the library when Postgres
// starts (`shared_preload_libraries`, a host-side setting), and the extension
// object is created once in the database. The server does the second step at
// startup when it finds the first (`enableIfPreloaded`), so no new setting is
// needed on the server side. See docs/operational-diagnostics.md
// §"Database statement timing".
//
// Privacy: Postgres normalizes a SELECT, INSERT, UPDATE, DELETE or MERGE
// before it stores it, and replaces every constant with a placeholder ($1,
// $2, ...). It does not normalize a utility statement (SET, DO, COPY, ...),
// which keeps its literals, so the reads below return only the first kind
// (`normalizedStatementFilter`).

import Fluent
import SQLKit
import Vapor

enum QueryStatistics {
    enum Availability: String, Sendable, Equatable {
        /// The database is not Postgres (SQLite has no equivalent).
        case notPostgres
        /// Postgres did not load the library at startup.
        case notPreloaded
        /// The library is loaded, but the extension object does not exist.
        case extensionMissing
        case ready

        /// What the operator must do, or nil when the statistics are ready.
        var note: String? {
            switch self {
            case .notPostgres:
                return "Statement timing needs Postgres. This server uses SQLite."
            case .notPreloaded:
                return
                    "Postgres did not load pg_stat_statements. Add "
                    + "\"-c shared_preload_libraries=pg_stat_statements\" to the db service command and "
                    + "restart the db container. See docs/operational-diagnostics.md."
            case .extensionMissing:
                return
                    "pg_stat_statements is loaded, but the extension does not exist in this database. "
                    + "The server creates it at startup; if that failed, run "
                    + "\"CREATE EXTENSION pg_stat_statements SCHEMA public;\" as a superuser."
            case .ready:
                return nil
            }
        }
    }

    /// Keeps only the statements that Postgres normalizes. A utility
    /// statement keeps its literals, so it must never be returned.
    static let normalizedStatementFilter =
        "query ~* '^\\s*(select|insert|update|delete|merge|with|values|table)\\M'"

    /// The text Postgres shows for a statement that another role ran, when
    /// this role may not read it.
    static let hiddenQueryText = "<insufficient privilege>"

    /// The longest statement text returned. A long statement is cut, not
    /// dropped, so its row still counts.
    static let maximumQueryLength = 500

    static func availability(on db: Database) async throws -> Availability {
        guard let sql = db as? SQLDatabase, sql.dialect.name == "postgresql" else { return .notPostgres }
        guard try await isPreloaded(sql) else { return .notPreloaded }
        return try await extensionSchema(on: sql) == nil ? .extensionMissing : .ready
    }

    /// The schema that holds the extension's views, or nil when the
    /// extension does not exist. An extension exists once per database, but
    /// not always in the schema on the search path, so every read names it.
    static func extensionSchema(on sql: SQLDatabase) async throws -> String? {
        let row = try await sql.raw(
            """
            SELECT n.nspname AS schema_name
            FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
            WHERE e.extname = 'pg_stat_statements'
            """
        ).first()
        return try row?.decode(column: "schema_name", as: String.self)
    }

    /// Creates the extension when the library is loaded and the extension is
    /// missing. Called once at startup. A failure is logged, never thrown:
    /// statement timing is diagnosis, and must not stop the server.
    static func enableIfPreloaded(on db: Database, logger: Logger) async {
        do {
            guard try await availability(on: db) == .extensionMissing, let sql = db as? SQLDatabase else {
                return
            }
            // In `public`, not the first schema on the search path: the
            // extension is database-wide, and a fixed home keeps it out of
            // any schema the application owns.
            try await sql.raw("CREATE EXTENSION IF NOT EXISTS pg_stat_statements SCHEMA public").run()
            logger.info("pg_stat_statements_enabled")
        } catch {
            // Two colors of a blue-green deploy can start together, and the
            // second CREATE then fails on the first one's row. The extension
            // exists either way, so check before reporting a failure.
            if (try? await availability(on: db)) == .ready {
                logger.info("pg_stat_statements_enabled")
                return
            }
            logger.warning(
                "pg_stat_statements_enable_failed",
                metadata: ["error": .string(String(describing: error))])
        }
    }

    /// The statements of this database, ordered by `order`, most first.
    static func topStatements(
        on sql: SQLDatabase,
        schema: String,
        orderedBy order: QueryStatisticsOrder,
        limit: Int
    ) async throws -> [QueryStatementStat] {
        // `order.column` comes from a closed enum, so it is safe to splice.
        let rows = try await sql.raw(
            """
            SELECT queryid, calls, total_exec_time, mean_exec_time, max_exec_time,
                   rows, shared_blks_hit, shared_blks_read,
                   left(query, \(literal: maximumQueryLength)) AS query
            FROM \(ident: schema).pg_stat_statements
            WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
              AND (\(unsafeRaw: normalizedStatementFilter) OR query = \(literal: hiddenQueryText))
            ORDER BY \(unsafeRaw: order.column) DESC
            LIMIT \(bind: limit)
            """
        ).all()
        return try rows.map(QueryStatementStat.init(row:))
    }

    /// The totals over every statement of this database.
    static func totals(on sql: SQLDatabase, schema: String) async throws -> (calls: Int, totalExecMs: Double) {
        let row = try await sql.raw(
            """
            SELECT coalesce(sum(calls), 0)::bigint AS calls,
                   coalesce(sum(total_exec_time), 0)::double precision AS total_exec_time
            FROM \(ident: schema).pg_stat_statements
            WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
            """
        ).first()
        guard let row else { return (0, 0) }
        return (
            Int(try row.decode(column: "calls", as: Int64.self)),
            try row.decode(column: "total_exec_time", as: Double.self)
        )
    }

    /// When the statistics were last reset, from `pg_stat_statements_info`
    /// (Postgres 14 or later). Nil when the view does not exist.
    static func statsResetAt(on sql: SQLDatabase, schema: String) async -> Date? {
        let row = try? await sql.raw("SELECT stats_reset FROM \(ident: schema).pg_stat_statements_info").first()
        return try? row?.decode(column: "stats_reset", as: Date.self)
    }

    private static func isPreloaded(_ sql: SQLDatabase) async throws -> Bool {
        let row = try await sql.raw("SELECT current_setting('shared_preload_libraries') AS libraries").first()
        let libraries = try row?.decode(column: "libraries", as: String.self) ?? ""
        return libraries.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .contains("pg_stat_statements")
    }
}
