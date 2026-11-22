import Fluent
import Foundation
import SQLKit
import Testing
import VaporTesting

@testable import APIServer

/// The tool on the test database. Each test checks the answer the database
/// must give whether or not it loaded pg_stat_statements, so none skips. The
/// tests at the end make the request's database a scripted one
/// (`ScriptedQueryStatistics.swift`), so the tool's ready and unavailable
/// paths run on every database.
@Suite(.serialized) final class GetQueryStatsToolTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "query-stats")
    }

    private func context() -> AdminToolContext {
        adminMCPContext(app, subject: "ops-admin")
    }

    @Test func availabilityAnswersOnTheTestDatabase() async throws {
        try await withApp(app) { app in
            let availability = try await QueryStatistics.availability(on: app.db)
            #expect(
                [.notPreloaded, .extensionMissing, .ready].contains(availability),
                "\(availability)")
        }
    }

    /// Unavailable statistics are an answer with a note, not an error: an
    /// agent needs to know what to ask the operator for.
    @Test func toolExplainsUnavailableStatistics() async throws {
        try await withApp(app) { app in
            let availability = try await QueryStatistics.availability(on: app.db)
            let output = try await GetQueryStatsTool().execute(.init(), context())
            #expect(output.state == availability.rawValue)
            #expect(output.orderBy == "total")
            if availability == .ready {
                #expect(output.available)
                #expect(output.note == nil)
            } else {
                #expect(!output.available)
                #expect(output.note == availability.note)
                #expect(output.statements.isEmpty)
            }
        }
    }

    /// Where the extension is loaded, a statement the test runs shows up,
    /// and a constant in it does not.
    @Test func readyStatisticsListNormalizedStatements() async throws {
        try await withApp(app) { app in
            guard try await QueryStatistics.availability(on: app.db) == .ready,
                let sql = app.db as? any SQLDatabase
            else {
                // A trait cannot ask the database, so this branch is the
                // check for a database without the extension: nothing to list.
                #expect(try await QueryStatistics.availability(on: app.db) != .ready)
                return
            }
            try await sql.raw("SELECT 'query-stats-secret-value' AS marker").run()
            // Postgres does not normalize a utility statement: its literal
            // stays in the stored text, so the tool must filter it out.
            try await sql.raw("SET application_name = 'query-stats-utility-secret'").run()
            try await sql.raw("DO $$ BEGIN PERFORM 'query-stats-do-secret'; END $$").run()

            let output = try await GetQueryStatsTool().execute(
                .init(orderBy: "calls", limit: 50), context())
            #expect(output.available)
            #expect(output.statements.count <= 50)
            for marker in ["query-stats-secret-value", "query-stats-utility-secret", "query-stats-do-secret"] {
                #expect(output.statements.allSatisfy { !$0.query.contains(marker) })
            }
            #expect(output.statements.allSatisfy { $0.query.count <= QueryStatistics.maximumQueryLength })
            let calls = output.statements.map(\.calls)
            #expect(calls == calls.sorted(by: >))
        }
    }

    /// The startup step makes a loaded library usable, and changes nothing
    /// on a database that cannot have the extension.
    @Test func startupEnablesALoadedLibrary() async throws {
        try await withApp(app) { app in
            let before = try await QueryStatistics.availability(on: app.db)
            await QueryStatistics.enableIfPreloaded(on: app.db, logger: app.logger)
            let after = try await QueryStatistics.availability(on: app.db)
            switch before {
            case .extensionMissing, .ready:
                #expect(after == .ready)
            case .notPreloaded:
                #expect(after == before)
            }
        }
    }

    @Test func unknownOrderIsRefused() async throws {
        try await withApp(app) { _ in
            await #expect(throws: MCPToolError.self) {
                try await GetQueryStatsTool().execute(.init(orderBy: "fastest"), context())
            }
        }
    }

    // MARK: - On statistics the test controls

    /// The ready path, end to end: the request's database says the library
    /// is loaded and names a schema of the test's own, so the tool reads rows
    /// the test wrote. The totals count every statement of this database; the
    /// list keeps only normalized ones, cut to the limit, each with its share.
    @Test func readyStatisticsReportTheTopStatementsAndTheirShare() async throws {
        try await withApp(app) { app in
            try await withQueryStatsSchema(app) { sql, schema in
                try await insertQueryStats(
                    [
                        .init(id: 1, query: "SELECT * FROM users WHERE id = $1", calls: 3, total: 60, hit: 3, read: 1),
                        .init(id: 2, query: "INSERT INTO logs VALUES ($1)", total: 30),
                        .init(id: 3, query: "SELECT $1, $2", total: 5),
                        .init(id: 4, query: "SET application_name = 'tool-utility-secret'", total: 5),
                        .init(id: 5, query: "SELECT $1", calls: 900, total: 900, otherDatabase: true),
                    ], into: schema, on: sql)
                let reset = Date(timeIntervalSince1970: 1_790_000_000)
                try await sql.raw(
                    "INSERT INTO \(ident: schema).pg_stat_statements_info (stats_reset) VALUES (\(bind: reset))"
                ).run()
                try app.useScriptedCatalog(
                    CatalogScript(libraries: "pg_stat_statements", extensionSchema: schema))

                let output = try await GetQueryStatsTool().execute(.init(limit: 2), context())

                #expect(output.available)
                #expect(output.state == "ready")
                #expect(output.note == nil)
                #expect(output.orderBy == "total")
                #expect(output.totalCalls == 6)
                #expect(output.totalExecMs == 100)
                let resetAt = try #require(output.statsResetAt)
                #expect(abs(resetAt.timeIntervalSince(reset)) < 0.001)
                #expect(output.statements.map(\.queryID) == ["1", "2"])
                #expect(output.statements.map(\.shareOfTotalPercent) == [60, 30])
                #expect(output.statements.map(\.cacheHitPercent) == [75, nil])
                #expect(output.statements.first?.calls == 3)
            }
        }
    }

    /// Another role's statement comes back as placeholder text. The tool
    /// says why and what grant shows it. Postgres before 14 has no info view,
    /// which is no reset date, not an error.
    @Test func hiddenStatementTextIsExplained() async throws {
        try await withApp(app) { app in
            try await withQueryStatsSchema(app, withInfoView: false) { sql, schema in
                try await insertQueryStats(
                    [
                        .init(id: 1, query: QueryStatistics.hiddenQueryText, total: 10),
                        .init(id: 2, query: "SELECT $1", total: 5),
                    ], into: schema, on: sql)
                try app.useScriptedCatalog(
                    CatalogScript(libraries: "pg_stat_statements", extensionSchema: schema))

                let output = try await GetQueryStatsTool().execute(.init(orderBy: "calls"), context())

                #expect(output.available)
                #expect(output.orderBy == "calls")
                #expect(output.note?.contains("pg_read_all_stats") == true)
                #expect(output.statsResetAt == nil)
                #expect(output.statements.count == 2)
            }
        }
    }

    /// Each unavailable state, whatever the test database has loaded: the
    /// tool returns the state and its note, and reads no statistics.
    @Test(
        arguments: [
            ("auto_explain", "public", QueryStatistics.Availability.notPreloaded),
            ("pg_stat_statements", nil, .extensionMissing),
        ] as [(String, String?, QueryStatistics.Availability)])
    func unavailableStatesAreReportedWithTheirNote(
        libraries: String, extensionSchema: String?, expected: QueryStatistics.Availability
    ) async throws {
        try await withApp(app) { app in
            let script = CatalogScript(libraries: libraries, extensionSchema: extensionSchema)
            try app.useScriptedCatalog(script)

            let output = try await GetQueryStatsTool().execute(.init(), context())

            #expect(!output.available)
            #expect(output.state == expected.rawValue)
            #expect(output.note == expected.note)
            #expect(output.totalCalls == nil)
            #expect(output.statements.isEmpty)
            #expect(!script.statements.contains { $0.contains("pg_stat_statements_info") })
        }
    }
}
