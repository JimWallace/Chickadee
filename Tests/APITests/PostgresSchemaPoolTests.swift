// Tests/APITests/PostgresSchemaPoolTests.swift
//
// Guards for the pre-migrated Postgres schema pool in TestHelpers.swift.
//
// Three properties are load-bearing and none of them is visible in a green
// run: that a schema comes back even when the test that borrowed it blew up,
// that a schema which came back CHANGED is caught rather than recycled, and
// that an empty pool blocks instead of growing. Each is asserted directly
// here, against a pool of this file's own so that proving "an empty pool
// blocks" does not block the rest of the suite.
//
// The fourth guard has nothing to do with the pool's mechanics: it reads the
// test sources and fails if a suite changes its database's shape without being
// declared in `SchemaMutatingSuites`. That list is the one place this design
// names a suite, and this is what stops the names going stale silently.

import Fluent
import Foundation
import SQLKit
import Testing
import Vapor

@testable import APIServer

@Suite struct PostgresSchemaPoolTests {

    // MARK: - The declared-suite guard

    /// `Tests/APITests`, resolved from this file's location.
    private static var apiTestSources: URL {
        var url = URL(fileURLWithPath: #filePath)  // .../Tests/APITests/<thisFile>
        url.deleteLastPathComponent()
        return url
    }

    /// Source fragments that mean "this suite changes its database's shape".
    ///
    /// Behaviour, not names. `MigrationLog` is the model whose rows ARE the
    /// history; `reconcileLegacyMigrationNamespace` rewrites them wholesale;
    /// `.revert(on:` undoes a migration's DDL; `.schema(` is Fluent's DDL
    /// builder, which is how the one suite this scan found that a hand search
    /// had missed drops a table. Renaming any of those suites changes nothing
    /// here — the scan finds the new name and demands it be declared.
    ///
    /// It over-approximates on purpose: a suite that only READS `MigrationLog`
    /// is flagged too, and so is one whose DDL never reaches a pooled schema.
    /// Over-approximating costs that suite one freshly migrated schema per
    /// test; under-approximating costs every test scheduled after it on the
    /// same pooled schema.
    private static let schemaMutationTokens = [
        "MigrationLog",
        "reconcileLegacyMigrationNamespace",
        ".revert(on:",
        ".schema(",
    ]

    /// DDL keywords that only count when the same line also EXECUTES SQL.
    /// `sql.raw("CREATE TABLE …")` changes a schema; a test asserting that a
    /// rendered script contains `ALTER TABLE …` does not, and a scan that
    /// cannot tell them apart fills the declared list with inert names.
    private static let rawDDLKeywords = [
        "CREATE TABLE", "DROP TABLE", "ALTER TABLE",
        "CREATE INDEX", "DROP INDEX", "TRUNCATE",
    ]

    /// Names the suites in `source` that carry any mutation token.
    ///
    /// A deliberately blunt parse: track the most recent type declaration and
    /// attribute a token to it. Attribution can only be too coarse (a second
    /// suite in the same file), never too narrow, and too coarse fails safe —
    /// it demands a declaration that costs a fresh schema.
    static func schemaMutatingSuites(in source: String) -> Set<String> {
        let declaration = try? NSRegularExpression(
            pattern: #"\b(?:struct|final class|class|enum|actor)\s+([A-Za-z_]\w*)"#)
        var current: String?
        var found: Set<String> = []
        for line in source.components(separatedBy: "\n") {
            if let declaration,
                let match = declaration.firstMatch(
                    in: line, options: [], range: NSRange(line.startIndex..., in: line)),
                let range = Range(match.range(at: 1), in: line)
            {
                current = String(line[range])
            }
            let executesRawDDL =
                line.contains(".raw(")
                && rawDDLKeywords.contains(where: line.uppercased().contains)
            guard executesRawDDL || schemaMutationTokens.contains(where: line.contains)
            else { continue }
            if let current { found.insert(current) }
        }
        return found
    }

    private func swiftFiles(under root: URL) throws -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    @Test func everySchemaMutatingSuiteIsDeclared() throws {
        let files = try swiftFiles(under: Self.apiTestSources)
        #expect(!files.isEmpty)  // sanity: the directory resolved

        var found: Set<String> = []
        var scanned = 0
        for file in files {
            // This file is the guard, and it quotes the tokens it looks for.
            // Everything else is scanned, including TestHelpers.swift — the
            // scan keys on `@Test`-bearing files below, and a helper with no
            // tests declares no suite to flag.
            guard file.lastPathComponent != URL(fileURLWithPath: #filePath).lastPathComponent
            else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            guard source.contains("@Test") else { continue }
            scanned += 1
            found.formUnion(Self.schemaMutatingSuites(in: source))
        }

        #expect(scanned > 100)  // the scan had real input
        #expect(
            found == SchemaMutatingSuites.names,
            """
            The suites that change their database's shape have changed. \
            SchemaMutatingSuites.names in Tests/APITests/TestHelpers.swift says \
            \(SchemaMutatingSuites.names.sorted()); the sources say \(found.sorted()). \
            A suite that rewrites its schema or its migration log must be declared there so \
            it gets a freshly migrated Postgres schema instead of one recycled out of the pool.
            """)
    }

    /// The guard above, seen to fail.
    ///
    /// A scan that returns the declared set is indistinguishable from a scan
    /// that returns nothing at all, which is the shape this repository has
    /// been burned by repeatedly. So the detector is run against a suite that
    /// does not exist and must both find it and find it undeclared.
    @Test func theScanFindsUndeclaredSuitesAndIgnoresMereMentions() throws {
        let synthetic = """
            @Suite struct InventedLaterMigrationTests {
                @Test func undoesOne() async throws {
                    try await CreateSweepLeases().revert(on: app.db)
                }
            }
            @Suite struct InventedLaterDDLTests {
                @Test func dropsOne() async throws {
                    try await app.db.schema("audit_log").delete()
                }
            }
            @Suite struct InventedLaterAssertionTests {
                @Test func readsOne() throws {
                    #expect(rendered.contains("ALTER TABLE x ENABLE ROW LEVEL SECURITY"))
                }
            }
            """
        let found = Self.schemaMutatingSuites(in: synthetic)
        // Both mutators found, and the suite that merely ASSERTS on DDL text
        // not flagged — over-approximating is safe, but a scan that flags
        // every mention fills the declared list with inert names.
        #expect(found == ["InventedLaterMigrationTests", "InventedLaterDDLTests"])
        #expect(SchemaMutatingSuites.names.isDisjoint(with: found))
    }

    // MARK: - The sequence claim

    /// The sweep is a DELETE, and DELETE does not reset a sequence — so a
    /// recycled schema would keep counting up where the previous test stopped.
    /// The pool refuses to recycle a schema that has any sequence at all
    /// (`PostgresSchemaPoolError.databaseGeneratedSequencesFound`), which is
    /// the runtime half of this claim and cannot be fooled by a spelling.
    ///
    /// This is the source half, and it runs on both lanes: no model asks the
    /// database to generate an identifier, and no migration declares an
    /// auto-incrementing one. It is what makes the runtime refusal a guard
    /// against a future change rather than a check that fails today.
    @Test func noModelUsesADatabaseGeneratedIdentifier() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }  // -> repo root
        let sources = root.appendingPathComponent("Sources/APIServer")
        let files = try swiftFiles(under: sources)
        #expect(!files.isEmpty)

        var identifierDeclarations = 0
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.components(separatedBy: "\n") {
                if line.contains("@ID(") {
                    identifierDeclarations += 1
                    #expect(
                        line.contains("@ID(key: .id)") || line.contains("generatedBy: .user"),
                        "database-generated identifier in \(file.lastPathComponent): \(line)")
                }
                if line.contains(".identifier(") {
                    identifierDeclarations += 1
                    #expect(
                        line.contains("auto: false"),
                        "auto-increment identifier in \(file.lastPathComponent): \(line)")
                }
                #expect(
                    !line.uppercased().contains("CREATE SEQUENCE"),
                    "raw sequence in \(file.lastPathComponent): \(line)")
            }
        }
        #expect(identifierDeclarations > 40)  // the scan had real input
    }

    // MARK: - Pool mechanics

    private func testSettings() async throws -> DatabaseSettings {
        try await withAsyncEnvLock { try testDatabaseSettingsFromEnvironment() }
    }

    /// Runs `body` against a pool of this test's own, and drops its schemas
    /// however the body ends.
    private func withPrivatePool(
        capacity: Int,
        checkoutTimeout: Duration = .seconds(90),
        _ body: (MigratedPostgresSchemaPool, DatabaseSettings) async throws -> Void
    ) async throws {
        let settings = try await testSettings()
        let pool = MigratedPostgresSchemaPool(
            capacity: capacity, checkoutTimeout: checkoutTimeout)
        do {
            try await body(pool, settings)
        } catch {
            await pool.shutDownAndDropEverything()
            throw error
        }
        await pool.shutDownAndDropEverything()
    }

    /// Opens an Application pointed at `schema`, runs `body`, and shuts down.
    private func withSchemaConnection(
        _ schema: String, settings: DatabaseSettings,
        _ body: (Application) async throws -> Void
    ) async throws {
        let app = try await Application.make(.testing)
        do {
            app.logger.logLevel = .warning
            try configureDatabase(
                app, settings: try postgresSettings(settings, searchPath: [schema]))
            try await body(app)
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    private func rowCount(_ table: String, on app: Application) async throws -> Int {
        struct CountRow: Decodable { let count: Int }
        let sql = try #require(app.db as? SQLDatabase)
        return try await sql.raw("SELECT count(*)::int AS count FROM \(unsafeRaw: table)")
            .first(decoding: CountRow.self)?.count ?? -1
    }

    /// Hazard: a test whose body throws must still hand its schema back, or
    /// the pool loses capacity and the run eventually blocks on an empty pool.
    ///
    /// Asserted on both lanes, against whatever that lane's per-test database
    /// actually is: the pooled lease on Postgres, the migrated-template copy
    /// on SQLite. The SQLite branch also pins that the pool never engages
    /// there at all, which is the other thing this change must not get wrong.
    @Test func aThrowingTestBodyStillReleasesItsTestDatabase() async throws {
        struct DeliberateFailure: Error {}

        let app = try await makeTestApp(prefix: "chickadee-pool-throw")
        let lease = app.storage[PooledPostgresSchemaKey.self]
        let templateCopy = app.storage[TestSQLiteDatabaseFileKey.self]

        await #expect(throws: DeliberateFailure.self) {
            try await withApp(app) { _ in throw DeliberateFailure() }
        }

        switch try await testSettings().backend {
        case .postgres:
            let lease = try #require(lease, "the postgres lane must hand out a pooled lease")
            #expect(!(await MigratedPostgresSchemaPool.shared.isOutstanding(lease)))
        case .sqlite:
            let copy = try #require(templateCopy, "the sqlite lane must hand out a template copy")
            #expect(!FileManager.default.fileExists(atPath: copy))
            #expect(await MigratedPostgresSchemaPool.shared.statistics().schemasCreated == 0)
        }
    }

    /// The sweep empties the schema and leaves the migration log alone — the
    /// two halves of "a recycled schema is indistinguishable from a freshly
    /// migrated one".
    @Test func aReturnedSchemaComesBackEmptyWithItsMigrationLogIntact() async throws {
        guard try await testSettings().backend == .postgres else {
            // There is no pool on the sqlite lane, so the assertion that
            // belongs here is the one that lane DOES owe: that this change
            // never reached it. A silent return would be the skip this
            // repository keeps getting burned by.
            #expect(await MigratedPostgresSchemaPool.shared.statistics().schemasCreated == 0)
            return
        }
        try await withPrivatePool(capacity: 1) { pool, settings in
            let first = try await pool.checkOut(settings: settings, logLevel: .warning)
            var migrationsBefore = 0
            try await withSchemaConnection(first.schemaName, settings: settings) { app in
                migrationsBefore = try await self.rowCount("_fluent_migrations", on: app)
                try await APICourse(code: "POOL101", name: "Pool", enrollmentMode: .open)
                    .save(on: app.db)
            }
            #expect(migrationsBefore > 40)  // the schema really was migrated

            try await pool.checkIn(first)
            let second = try await pool.checkOut(settings: settings, logLevel: .warning)
            #expect(second.schemaName == first.schemaName)  // recycled, not rebuilt

            try await withSchemaConnection(second.schemaName, settings: settings) { app in
                let courses = try await self.rowCount("courses", on: app)
                let migrations = try await self.rowCount("_fluent_migrations", on: app)
                #expect(courses == 0)
                #expect(migrations == migrationsBefore)
            }
            try await pool.checkIn(second)
        }
    }

    /// Hazard: a schema that comes back structurally changed must not be
    /// recycled — and refusing it must not cost the pool the capacity, or one
    /// bad test wedges every test after it.
    @Test func aStructurallyChangedSchemaIsRefusedAndReplaced() async throws {
        guard try await testSettings().backend == .postgres else {
            // There is no pool on the sqlite lane, so the assertion that
            // belongs here is the one that lane DOES owe: that this change
            // never reached it. A silent return would be the skip this
            // repository keeps getting burned by.
            #expect(await MigratedPostgresSchemaPool.shared.statistics().schemasCreated == 0)
            return
        }
        try await withPrivatePool(capacity: 1) { pool, settings in
            let lease = try await pool.checkOut(settings: settings, logLevel: .warning)
            try await withSchemaConnection(lease.schemaName, settings: settings) { app in
                // Stands in for the damage the declared suites would do: any
                // change to the schema's shape or its migration log.
                let sql = try #require(app.db as? SQLDatabase)
                try await sql.raw("CREATE TABLE pool_guard_probe (id text primary key)").run()
            }

            await #expect(throws: (any Error).self) { try await pool.checkIn(lease) }
            #expect(!(await pool.isOutstanding(lease)))

            let statistics = await pool.statistics()
            #expect(statistics.schemasCreated == 1)  // replaced, not lost

            let replacement = try await pool.checkOut(settings: settings, logLevel: .warning)
            #expect(replacement.schemaName != lease.schemaName)
            try await pool.checkIn(replacement)
        }
    }

    /// Hazard: an exhausted pool must BLOCK, not quietly migrate an
    /// unbounded number of extra schemas.
    ///
    /// Driven against a capacity-1 pool with a short wait bound, because the
    /// honest version of this assertion on the shared pool is "stall every
    /// other test for 90 seconds".
    @Test func anExhaustedPoolBlocksInsteadOfCreatingMoreSchemas() async throws {
        guard try await testSettings().backend == .postgres else {
            // There is no pool on the sqlite lane, so the assertion that
            // belongs here is the one that lane DOES owe: that this change
            // never reached it. A silent return would be the skip this
            // repository keeps getting burned by.
            #expect(await MigratedPostgresSchemaPool.shared.statistics().schemasCreated == 0)
            return
        }
        let shortWait = Duration.milliseconds(750)
        try await withPrivatePool(capacity: 1, checkoutTimeout: shortWait) { pool, settings in
            let held = try await pool.checkOut(settings: settings, logLevel: .warning)
            #expect(await pool.statistics().schemasCreated == 1)

            await #expect(throws: PostgresSchemaPoolError.self) {
                _ = try await pool.checkOut(settings: settings, logLevel: .warning)
            }
            // The blocked checkout waited for a return; it did not grow the pool.
            #expect(await pool.statistics().schemasCreated == 1)

            try await pool.checkIn(held)
            let next = try await pool.checkOut(settings: settings, logLevel: .warning)
            #expect(await pool.statistics().schemasCreated == 1)
            try await pool.checkIn(next)
        }
    }
}
