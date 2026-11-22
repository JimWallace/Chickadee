// Tests/APITests/Admin/QueryStatisticsTests.swift
//
// `QueryStatistics` reads Postgres's pg_stat_statements. `QueryStatisticsTests`
// checks the parts that need no database. The test database does not load
// that library, so `QueryStatisticsDatabaseTests` runs the reads and the
// startup step that creates the extension on the test database in two ways,
// with no change to the database's settings:
//
// - The availability check and `enableIfPreloaded` run through a database
//   that answers the two catalog questions (is the library loaded, where is
//   the extension) from a script, and records the CREATE EXTENSION statement
//   instead of running it. Every other statement goes to Postgres.
// - The statement reads run against a schema of the test's own that holds
//   tables shaped like the extension's two views. The reads name their schema,
//   so the real SQL (the filter that keeps literals out, the order, the limit,
//   the cut) runs against rows the test controls.
//
// Both fixtures are in `ScriptedQueryStatistics.swift`, which the tool tests
// share.

import Fluent
import Foundation
import Logging
import NIOCore
import SQLKit
import Testing
import VaporTesting

@testable import APIServer

@Suite struct QueryStatisticsTests {
    @Test(arguments: [
        (QueryStatisticsOrder.total, "total_exec_time"),
        (.mean, "mean_exec_time"),
        (.calls, "calls"),
    ])
    func orderSortsByItsColumn(order: QueryStatisticsOrder, column: String) {
        #expect(order.column == column)
    }

    @Test func toolIsRegistered() {
        #expect(AdminMCPToolCatalog.live.all.contains { $0.name == GetQueryStatsTool.name })
    }

    @Test func orderDefaultsToTotalTime() throws {
        #expect(try GetQueryStatsTool.resolveOrder(nil) == .total)
        #expect(try GetQueryStatsTool.resolveOrder("mean") == .mean)
    }

    @Test func everyUnavailableStateTellsTheOperatorWhatToDo() {
        for state in [QueryStatistics.Availability.notPreloaded, .extensionMissing] {
            #expect(state.note?.isEmpty == false)
        }
        #expect(QueryStatistics.Availability.ready.note == nil)
    }

    @Test func statementRoundsToTwoDecimalsAndComputesCacheHits() {
        let stat = QueryStatementStat(
            queryID: "42", query: "SELECT $1", calls: 3, totalMs: 10.12345, meanMs: 3.37448,
            maxMs: 5.0, rows: 3, sharedBlocksHit: 3, sharedBlocksRead: 1)
        #expect(stat.totalMs == 10.12)
        #expect(stat.meanMs == 3.37)
        #expect(stat.cacheHitPercent == 75)
    }

    @Test func statementWithNoBlockReadsHasNoCacheRate() {
        let stat = QueryStatementStat(
            queryID: "1", query: "SELECT 1", calls: 1, totalMs: 0.01, meanMs: 0.01,
            maxMs: 0.01, rows: 1, sharedBlocksHit: 0, sharedBlocksRead: 0)
        #expect(stat.cacheHitPercent == nil)
    }

    @Test func shareOfTotalIsAPercentOfAllTime() {
        let stat = QueryStatementStat(
            queryID: "7", query: "SELECT $1", calls: 1, totalMs: 25, meanMs: 25,
            maxMs: 25, rows: 1, sharedBlocksHit: 1, sharedBlocksRead: 0)
        #expect(GetQueryStatsTool.Statement(stat, totalExecMs: 100).shareOfTotalPercent == 25)
        #expect(GetQueryStatsTool.Statement(stat, totalExecMs: 0).shareOfTotalPercent == nil)
    }
}

// MARK: - On the test database

@Suite(.serialized) final class QueryStatisticsDatabaseTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "query-stats-db")
    }

    // MARK: - Availability

    /// The setting is a comma-separated list, and Postgres may quote an
    /// entry. Only the exact library name counts.
    @Test(arguments: [
        ("pg_stat_statements", true),
        ("auto_explain, pg_stat_statements", true),
        (#"auto_explain,"pg_stat_statements""#, true),
        ("  pg_stat_statements  ", true),
        ("", false),
        ("auto_explain", false),
        ("pg_stat_statements_extra", false),
    ])
    func theLibraryCountsAsLoadedOnlyByItsExactName(libraries: String, loaded: Bool) async throws {
        try await withApp(app) { app in
            let script = CatalogScript(libraries: libraries, extensionSchema: "public")
            let availability = try await QueryStatistics.availability(on: try scripted(app, script))
            #expect(availability == (loaded ? .ready : .notPreloaded))
        }
    }

    @Test func aLoadedLibraryWithoutTheExtensionIsExtensionMissing() async throws {
        try await withApp(app) { app in
            let script = CatalogScript(libraries: "pg_stat_statements", extensionSchema: nil)
            let database = try scripted(app, script)
            #expect(try await QueryStatistics.availability(on: database) == .extensionMissing)
        }
    }

    /// When the library is not loaded, the extension's catalog is not read.
    @Test func anUnloadedLibraryDoesNotAskForTheExtension() async throws {
        try await withApp(app) { app in
            let script = CatalogScript(libraries: "auto_explain", extensionSchema: "public")
            let database = try scripted(app, script)
            #expect(try await QueryStatistics.availability(on: database) == .notPreloaded)
            #expect(!script.statements.contains { $0.contains("pg_extension") })
        }
    }

    /// The real catalog read: on a database where the extension exists, it
    /// names the schema; where it does not, nil. Both answers must agree with
    /// what Postgres's catalog says.
    @Test func theExtensionSchemaReadAgreesWithTheCatalog() async throws {
        try await withApp(app) { app in
            let sql = try #require(app.db as? any SQLDatabase)
            let catalog = try await sql.raw(
                "SELECT count(*)::bigint AS n FROM pg_extension WHERE extname = 'pg_stat_statements'"
            ).first()?.decode(column: "n", as: Int64.self)
            let schema = try await QueryStatistics.extensionSchema(on: sql)
            #expect((schema != nil) == (catalog == 1), "schema \(String(describing: schema))")
        }
    }

    // MARK: - Enabling at startup

    @Test func aMissingExtensionIsCreatedInPublic() async throws {
        try await withApp(app) { app in
            let script = CatalogScript(libraries: "pg_stat_statements", extensionSchema: nil)
            let log = CapturedLog()
            await QueryStatistics.enableIfPreloaded(on: try scripted(app, script), logger: log.logger)

            let creates = script.statements.filter { $0.hasPrefix("CREATE EXTENSION") }
            #expect(creates == ["CREATE EXTENSION IF NOT EXISTS pg_stat_statements SCHEMA public"])
            #expect(log.records == [.init(level: .info, message: "pg_stat_statements_enabled")])
        }
    }

    @Test(
        arguments: [
            ("auto_explain", "public"),
            ("pg_stat_statements", "public"),
        ] as [(String, String?)])
    func noExtensionIsCreatedUnlessItIsMissing(libraries: String, extensionSchema: String?) async throws {
        try await withApp(app) { app in
            let script = CatalogScript(libraries: libraries, extensionSchema: extensionSchema)
            let log = CapturedLog()
            await QueryStatistics.enableIfPreloaded(on: try scripted(app, script), logger: log.logger)

            #expect(!script.statements.contains { $0.hasPrefix("CREATE EXTENSION") })
            #expect(log.records.isEmpty)
        }
    }

    /// Two colors of a blue-green deploy can start together. The second
    /// CREATE fails on the first one's row, and the extension then exists.
    /// That is success, not a warning.
    @Test func aCreateThatLosesTheRaceToAnotherServerIsSuccess() async throws {
        try await withApp(app) { app in
            let script = CatalogScript(
                libraries: "pg_stat_statements", extensionSchema: nil, create: .failsButAnotherServerCreatesIt)
            let log = CapturedLog()
            await QueryStatistics.enableIfPreloaded(on: try scripted(app, script), logger: log.logger)

            #expect(log.records == [.init(level: .info, message: "pg_stat_statements_enabled")])
        }
    }

    /// A failure is logged and never thrown: statement timing must not stop
    /// the server.
    @Test func aCreateThatFailsIsAWarningWithTheError() async throws {
        try await withApp(app) { app in
            let script = CatalogScript(libraries: "pg_stat_statements", extensionSchema: nil, create: .fails)
            let log = CapturedLog()
            await QueryStatistics.enableIfPreloaded(on: try scripted(app, script), logger: log.logger)

            let message = try #require(log.records.first)
            #expect(log.records.count == 1)
            #expect(message.level == .warning)
            #expect(message.message == "pg_stat_statements_enable_failed")
            #expect(message.error?.contains("permissionDenied") == true, "\(String(describing: message.error))")
        }
    }

    // MARK: - Statement reads

    /// Only statements that Postgres normalizes are returned, plus the
    /// placeholder text for another role's statement. A utility statement
    /// keeps its literals, so it must never come back.
    @Test func topStatementsReturnsOnlyNormalizedStatementsOfThisDatabase() async throws {
        try await withApp(app) { app in
            try await withQueryStatsSchema(app) { sql, schema in
                try await insertQueryStats(
                    [
                        .init(id: 1, query: "SELECT * FROM users WHERE id = $1", total: 50),
                        .init(id: 2, query: "  with t as (select $1) select * from t", total: 40),
                        .init(id: 3, query: "INSERT INTO logs VALUES ($1)", total: 30),
                        .init(id: 4, query: QueryStatistics.hiddenQueryText, total: 20),
                        .init(id: 5, query: "SET application_name = 'utility-secret'", total: 90),
                        .init(id: 6, query: "DO $$ BEGIN PERFORM 'do-secret'; END $$", total: 80),
                        .init(id: 7, query: "selection_is_not_a_keyword", total: 70),
                        .init(id: 8, query: "SELECT $1 FROM other_database", total: 99, otherDatabase: true),
                    ], into: schema, on: sql)

                let stats = try await QueryStatistics.topStatements(
                    on: sql, schema: schema, orderedBy: .total, limit: 50)
                #expect(stats.map(\.queryID) == ["1", "2", "3", "4"])
            }
        }
    }

    @Test(arguments: [
        (QueryStatisticsOrder.total, ["2", "1", "3"]),
        (.mean, ["3", "2", "1"]),
        (.calls, ["1", "3", "2"]),
    ])
    func topStatementsOrdersByTheChosenColumn(order: QueryStatisticsOrder, expected: [String]) async throws {
        try await withApp(app) { app in
            try await withQueryStatsSchema(app) { sql, schema in
                try await insertQueryStats(
                    [
                        .init(id: 1, query: "SELECT $1", calls: 100, total: 200, mean: 2),
                        .init(id: 2, query: "SELECT $1, $2", calls: 2, total: 300, mean: 150),
                        .init(id: 3, query: "SELECT $1, $2, $3", calls: 50, total: 100, mean: 900),
                    ], into: schema, on: sql)

                let stats = try await QueryStatistics.topStatements(
                    on: sql, schema: schema, orderedBy: order, limit: 10)
                #expect(stats.map(\.queryID) == expected)
            }
        }
    }

    /// The limit caps the rows, and a long statement is cut, not dropped.
    @Test func topStatementsHonoursTheLimitAndCutsLongText() async throws {
        try await withApp(app) { app in
            try await withQueryStatsSchema(app) { sql, schema in
                let long = "SELECT " + String(repeating: "x", count: QueryStatistics.maximumQueryLength * 2)
                try await insertQueryStats(
                    [
                        .init(id: 1, query: long, total: 30, hit: 3, read: 1),
                        .init(id: 2, query: "SELECT $1", total: 20),
                        .init(id: 3, query: "SELECT $2", total: 10),
                    ], into: schema, on: sql)

                let stats = try await QueryStatistics.topStatements(
                    on: sql, schema: schema, orderedBy: .total, limit: 2)
                #expect(stats.map(\.queryID) == ["1", "2"])
                let first = try #require(stats.first)
                #expect(first.query.count == QueryStatistics.maximumQueryLength)
                #expect(long.hasPrefix(first.query))
                #expect(first.cacheHitPercent == 75)
                #expect(first.totalMs == 30)
            }
        }
    }

    /// The totals cover every statement of this database, utility ones too,
    /// and no statement of another database.
    @Test func totalsSumEveryStatementOfThisDatabase() async throws {
        try await withApp(app) { app in
            try await withQueryStatsSchema(app) { sql, schema in
                try await insertQueryStats(
                    [
                        .init(id: 1, query: "SELECT $1", calls: 3, total: 10.5),
                        .init(id: 2, query: "SET search_path = 'x'", calls: 4, total: 2.25),
                        .init(id: 3, query: "SELECT $1", calls: 1000, total: 9999, otherDatabase: true),
                    ], into: schema, on: sql)

                let totals = try await QueryStatistics.totals(on: sql, schema: schema)
                #expect(totals.calls == 7)
                #expect(totals.totalExecMs == 12.75)
            }
        }
    }

    @Test func totalsOfAnEmptyViewAreZero() async throws {
        try await withApp(app) { app in
            try await withQueryStatsSchema(app) { sql, schema in
                let totals = try await QueryStatistics.totals(on: sql, schema: schema)
                #expect(totals.calls == 0)
                #expect(totals.totalExecMs == 0)
            }
        }
    }

    @Test func statsResetAtReadsTheInfoView() async throws {
        try await withApp(app) { app in
            try await withQueryStatsSchema(app) { sql, schema in
                let reset = Date(timeIntervalSince1970: 1_790_000_000)
                try await sql.raw(
                    "INSERT INTO \(ident: schema).pg_stat_statements_info (stats_reset) VALUES (\(bind: reset))"
                ).run()
                let read = try #require(await QueryStatistics.statsResetAt(on: sql, schema: schema))
                #expect(abs(read.timeIntervalSince(reset)) < 0.001)
            }
        }
    }

    /// Postgres before 14 has no info view. That is no date, not an error.
    @Test func statsResetAtIsNilWithoutTheInfoView() async throws {
        try await withApp(app) { app in
            try await withQueryStatsSchema(app, withInfoView: false) { sql, schema in
                #expect(await QueryStatistics.statsResetAt(on: sql, schema: schema) == nil)
            }
        }
    }

    // MARK: - Fixtures

    private func scripted(_ app: Application, _ script: CatalogScript) throws -> ScriptedCatalogDatabase {
        ScriptedCatalogDatabase(
            fluent: app.db, sql: try #require(app.db as? any SQLDatabase), script: script)
    }
}
