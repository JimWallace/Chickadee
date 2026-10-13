import Fluent
import SQLKit
import Testing
import VaporTesting

@testable import APIServer

/// The tool on the test database. The SQLite lane and the Postgres lane run
/// the same tests: each test checks the answer that its database must give,
/// so neither lane skips one.
@Suite(.serialized) final class GetQueryStatsToolTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "query-stats")
    }

    private func context() -> AdminToolContext {
        AdminToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "ops-admin",
            grantedScopes: [.read])
    }

    private var isPostgres: Bool {
        (app.db as? SQLDatabase)?.dialect.name == "postgresql"
    }

    @Test func availabilityMatchesTheDatabase() async throws {
        try await withApp(app) { app in
            let availability = try await QueryStatistics.availability(on: app.db)
            if isPostgres {
                #expect(availability != .notPostgres)
            } else {
                #expect(availability == .notPostgres)
            }
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
                let sql = app.db as? SQLDatabase
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
            case .notPostgres, .notPreloaded:
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
}
