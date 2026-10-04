// Tests/APITests/MigratedPostgresSchemaPool.swift
//
// A process-wide pool of pre-migrated Postgres schemas for test applications.

import Dispatch
import Fluent
import FluentPostgresDriver
import Foundation
import SQLKit
import Synchronization
import VaporTesting

@testable import APIServer

// MARK: - Postgres pre-migrated schema pool

/// The pooled, pre-migrated schema on loan to this Application.
///
/// Deliberately a DIFFERENT key from `TestPostgresSchemaKey`: that one marks a
/// schema this app OWNS and teardown DROPS, this one marks a schema this app
/// BORROWED and teardown must GIVE BACK. One key for both would be one `if let`
/// away from dropping a schema out from under the pool.
struct PooledPostgresSchemaKey: StorageKey {
    typealias Value = PostgresSchemaLease
}

/// One checkout of one pooled schema.
///
/// The `id` is what makes the pool's accounting observable without racing the
/// rest of the suite: schema NAMES are recycled, so "is `ck_pool_…_3` on loan?"
/// is answered by whichever test holds it now, but "is THIS checkout still
/// outstanding?" has exactly one answer. `PostgresSchemaPoolTests` asserts the
/// unconditional-return property through it.
struct PostgresSchemaLease: Sendable, Hashable {
    let id: UUID
    let schemaName: String
}

enum PostgresSchemaPoolError: Error, CustomStringConvertible {
    case notConfigured
    case noSQLDatabase
    case checkoutTimedOut(waited: Duration, capacity: Int)
    case databaseGeneratedSequencesFound([String])

    var description: String {
        switch self {
        case .notConfigured:
            return "MigratedPostgresSchemaPool used before any test supplied Postgres settings."
        case .noSQLDatabase:
            return "MigratedPostgresSchemaPool's maintenance application has no SQL database."
        case .checkoutTimedOut(let waited, let capacity):
            return """
                No pooled Postgres test schema became available within \(waited) (pool capacity \
                \(capacity)). Every schema is still on loan, which means either a test is holding \
                more applications at once than the pool has schemas, or a teardown failed to \
                return one. Raise MigratedPostgresSchemaPool.capacity only after checking which.
                """
        case .databaseGeneratedSequencesFound(let names):
            return """
                The migrated schema contains sequences (\(names.joined(separator: ", "))), which a \
                DELETE sweep does not reset — so a recycled schema would hand out identifiers that \
                continue from the previous test. Every identifier in Sources/APIServer/Models was \
                `.user`-generated and every `.identifier(` in Sources/APIServer/Migrations was \
                `auto: false` when the pool was written; one of them no longer is. Add \
                `ALTER SEQUENCE … RESTART` for each to the sweep statement.
                """
        }
    }
}

/// A process-wide pool of pre-migrated Postgres schemas, handed out one per
/// test Application and swept clean on return.
///
/// **Why.** Measured on this lane (local Postgres 16.13, the same probe shape
/// as the SQLite template note in `configureTestDatabase`):
/// `Application.make` + shutdown is 0.9 ms,
/// adding connect + `CREATE SCHEMA` takes it to 11.0 ms, and adding
/// `autoMigrate` takes it to 450.6 ms. **The 60 migrations are ~98 % of what a
/// Postgres test application costs**, which is the SQLite lane's finding again
/// on the lane that could not use the SQLite lane's fix.
///
/// **Why not a template database.** `CREATE DATABASE … TEMPLATE` is the obvious
/// analogue of the file copy, and it was spiked and rejected: 195.8 ms to
/// create plus 158.9 ms to drop, against ~460 ms to migrate. 1.3x is not worth
/// a second mechanism, and it needs a connection outside the test database to
/// issue it.
///
/// **Why a DELETE sweep.** Emptying the migrated schema's 44 tables costs
/// 139 ms with `TRUNCATE` (3.0x cheaper than migrating) and **1.7 ms with a
/// DELETE sweep in one `DO` block (244x)**. TRUNCATE is 44 catalog updates and
/// 44 file truncations; DELETE against tables one test left nearly empty is a
/// few pages of WAL. So a returned schema is emptied and handed straight back
/// out, and the per-test cost stops depending on the migration count at all —
/// the same O(1)-in-migrations property the SQLite template has.
///
/// An actor for the same reason `MigratedSQLiteTemplate` is one: the first
/// caller pays for a migration run and every other caller must wait for that
/// result rather than racing to build its own.
actor MigratedPostgresSchemaPool {
    static let shared = MigratedPostgresSchemaPool()

    /// How many schemas the pool will ever create.
    ///
    /// CI runs this target at `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=4`,
    /// so four test bodies are in flight at once and four schemas are the
    /// working set. 8 is twice that, and the doubling is not for speed:
    ///
    ///   * a body that builds a SECOND application while its first is alive
    ///     holds two schemas, and at width 4 that is 8. No APITests body does
    ///     today, but a pool sized exactly to the width would turn writing one
    ///     into a deadlock rather than a slowdown, and the deadlock would
    ///     surface as a lane burning to its ceiling — the failure shape this
    ///     whole entry is about;
    ///   * a checkout that arrives while several returns are mid-sweep should
    ///     not queue behind them.
    ///
    /// The cap costs nothing when it is not reached. Schemas are migrated ON
    /// DEMAND, so a run that never needs more than four builds four; this is a
    /// ceiling on unbounded growth, not a target.
    static let defaultCapacity = 8

    /// This pool's cap. An instance property rather than a constant so
    /// `PostgresSchemaPoolTests` can stand up a capacity-1 pool of its own and
    /// drive the blocking, the sweep and the fingerprint guard directly. A
    /// test that drained the SHARED pool to prove it blocks would block the
    /// rest of the run with it.
    let capacity: Int

    /// How long a checkout waits for a schema before failing.
    ///
    /// Blocking is the requirement — the alternative is creating schemas
    /// without bound, which is how a "pool" becomes a leak. Blocking FOREVER,
    /// though, is precisely the failure this document's Family 5 is about: a
    /// job that burns to its `timeout-minutes` ceiling having produced no
    /// evidence. A bounded wait turns a pool deadlock into one failed test
    /// that names the pool, 90 seconds after it happens. Nothing should ever
    /// reach it: the longest a borrower holds a schema is one test body.
    static let defaultCheckoutTimeout = Duration.seconds(90)

    /// This pool's wait bound. See `capacity` for why it is per-instance.
    let checkoutTimeout: Duration

    init(
        capacity: Int = MigratedPostgresSchemaPool.defaultCapacity,
        checkoutTimeout: Duration = MigratedPostgresSchemaPool.defaultCheckoutTimeout
    ) {
        self.capacity = capacity
        self.checkoutTimeout = checkoutTimeout
    }

    struct Statistics: Sendable {
        var schemasCreated: Int
        var schemasAvailable: Int
        var leasesOutstanding: Int
        var peakLeasesOutstanding: Int
        var waitingCheckouts: Int
    }

    /// A migrated schema plus the single statement that recycles it.
    private struct PreparedSchema: Sendable {
        let name: String
        /// The `DO` block built for THIS schema at migration time: fingerprint
        /// check, then the DELETE sweep. Built once because the table list and
        /// the migration log are fixed the moment the schema is migrated —
        /// re-deriving them per return would put two catalog queries in front
        /// of a 1.7 ms statement.
        let sweep: String
    }

    private var settings: DatabaseSettings?
    private var logLevel: Logger.Level = .warning
    private var maintenanceTask: Task<Application, any Error>?
    private var prepared: [String: PreparedSchema] = [:]
    private var available: [String] = []
    private var outstandingLeases: Set<UUID> = []
    private var created = 0
    private var nextSchemaIndex = 0
    private var peakLeasesOutstanding = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<String, any Error>)] = []

    /// A tag that makes this process's schemas identifiable in a database that
    /// several `swift test` processes may share, so a leftover set can be told
    /// from a live one by hand.
    private let poolTag = UUID().uuidString.lowercased()
        .replacingOccurrences(of: "-", with: "").prefix(8)

    func statistics() -> Statistics {
        Statistics(
            schemasCreated: created,
            schemasAvailable: available.count,
            leasesOutstanding: outstandingLeases.count,
            peakLeasesOutstanding: peakLeasesOutstanding,
            waitingCheckouts: waiters.count
        )
    }

    func isOutstanding(_ lease: PostgresSchemaLease) -> Bool {
        outstandingLeases.contains(lease.id)
    }

    /// Takes a migrated schema out of the pool, migrating a new one only while
    /// the pool is below `capacity` and otherwise WAITING for a return.
    func checkOut(
        settings: DatabaseSettings, logLevel: Logger.Level
    ) async throws
        -> PostgresSchemaLease
    {
        if self.settings == nil {
            self.settings = settings
            self.logLevel = logLevel
            PostgresSchemaPoolCleanup.register(self)
        }

        if let name = available.popLast() {
            return lease(on: name)
        }

        if created < capacity {
            // The slot is reserved BEFORE the first suspension. Actors are
            // reentrant across `await`, so a count incremented after the build
            // would let every concurrent first-caller through this test at
            // once — the same reentrancy hole that built the SQLite template
            // three times per run, recorded above.
            created += 1
            nextSchemaIndex += 1
            let index = nextSchemaIndex
            do {
                let schema = try await buildSchema(index: index)
                prepared[schema.name] = schema
                return lease(on: schema.name)
            } catch {
                created -= 1
                throw error
            }
        }

        return lease(on: try await waitForReturn())
    }

    /// Returns a schema to the pool, DELETE-sweeping it first.
    ///
    /// Throws when the schema came back structurally changed — but only AFTER
    /// the pool's capacity has been restored, by dropping that schema and
    /// migrating a replacement. A return path that could both fail and shrink
    /// the pool would let one bad test wedge every later one, which is the
    /// failure this whole mechanism must not introduce.
    func checkIn(_ lease: PostgresSchemaLease) async throws {
        outstandingLeases.remove(lease.id)
        guard let schema = prepared[lease.schemaName] else { return }
        do {
            try await sweep(schema)
            handBack(schema.name)
        } catch {
            await replace(schema)
            throw error
        }
    }

    /// Drops every schema this process created and shuts the maintenance
    /// application down. Called from `PostgresSchemaPoolCleanup` at exit.
    func shutDownAndDropEverything() async {
        let names = Array(prepared.keys)
        prepared.removeAll()
        available.removeAll()
        let task = maintenanceTask
        maintenanceTask = nil
        guard let app = try? await task?.value else { return }
        if let sql = app.db as? SQLDatabase {
            for name in names {
                try? await sql.raw(
                    "DROP SCHEMA IF EXISTS \(unsafeRaw: quotedIdentifier(name)) CASCADE"
                ).run()
            }
        }
        try? await app.asyncShutdown()
    }

    // MARK: Pool bookkeeping

    private func lease(on name: String) -> PostgresSchemaLease {
        let lease = PostgresSchemaLease(id: UUID(), schemaName: name)
        outstandingLeases.insert(lease.id)
        peakLeasesOutstanding = max(peakLeasesOutstanding, outstandingLeases.count)
        return lease
    }

    /// Gives a swept schema to the longest-waiting checkout, or parks it.
    private func handBack(_ name: String) {
        if waiters.isEmpty {
            available.append(name)
        } else {
            waiters.removeFirst().continuation.resume(returning: name)
        }
    }

    private func waitForReturn() async throws -> String {
        let id = UUID()
        // The timeout task inherits this actor's isolation, so `expireWaiter`
        // is a plain isolated call and cannot race the hand-back above it.
        let timeout = Task {
            try? await Task.sleep(for: checkoutTimeout)
            self.expireWaiter(id)
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append((id, continuation))
        }
    }

    private func expireWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(
            throwing: PostgresSchemaPoolError.checkoutTimedOut(
                waited: checkoutTimeout, capacity: capacity))
    }

    /// Drops a schema that came back unusable and migrates a replacement, so
    /// the pool's capacity survives a defect in one test.
    private func replace(_ schema: PreparedSchema) async {
        prepared[schema.name] = nil
        try? await dropSchema(named: schema.name)
        nextSchemaIndex += 1
        let index = nextSchemaIndex
        do {
            let rebuilt = try await buildSchema(index: index)
            prepared[rebuilt.name] = rebuilt
            handBack(rebuilt.name)
        } catch {
            // The replacement could not be built, so the pool really is one
            // schema smaller. Waiters parked on a return that is not coming
            // are failed here rather than left to the checkout timeout: the
            // database is in no state to serve them and a 90-second wait would
            // only delay the same answer.
            created -= 1
            let parked = waiters
            waiters.removeAll()
            for waiter in parked { waiter.continuation.resume(throwing: error) }
        }
    }

    // MARK: Schema construction and recycling

    private func buildSchema(index: Int) async throws -> PreparedSchema {
        guard let settings else { throw PostgresSchemaPoolError.notConfigured }
        let name = "ck_pool_\(poolTag)_\(index)"
        let sql = try await maintenanceSQL()
        try await sql.raw("CREATE SCHEMA \(unsafeRaw: quotedIdentifier(name))").run()
        do {
            try await migrate(schemaNamed: name, settings: settings)
            return PreparedSchema(name: name, sweep: try await sweepStatement(for: name, on: sql))
        } catch {
            try? await dropSchema(named: name)
            throw error
        }
    }

    /// Runs the 60 migrations into `name`, once, from a throwaway Application.
    ///
    /// A throwaway rather than the maintenance application because
    /// `search_path` is fixed when a pool is configured, and `autoMigrate`
    /// resolves unqualified names through it.
    private func migrate(schemaNamed name: String, settings: DatabaseSettings) async throws {
        let app = try await Application.make(.testing)
        do {
            // The same log-level squelch the per-application path used to
            // need, for the same reason (two FluentKit info lines per
            // migration) — except now it happens `capacity` times per process
            // instead of ~1,100.
            app.logger.logLevel = logLevel
            try configureDatabase(app, settings: try postgresSettings(settings, searchPath: [name]))
            registerMigrations(on: app)
            try await app.autoMigrate()
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    private func sweep(_ schema: PreparedSchema) async throws {
        let sql = try await maintenanceSQL()
        try await sql.raw("\(unsafeRaw: schema.sweep)").run()
    }

    private func dropSchema(named name: String) async throws {
        let sql = try await maintenanceSQL()
        try await sql.raw("DROP SCHEMA IF EXISTS \(unsafeRaw: quotedIdentifier(name)) CASCADE").run()
    }

    /// Builds the single statement that recycles `schema`: fingerprint check,
    /// then DELETE sweep, in one `DO` block and therefore one round trip.
    ///
    /// The fingerprint is the pool's own correctness guard, and it is keyed on
    /// the DAMAGE rather than on any suite, mechanism or name: it is an md5 of
    /// the schema's relations plus its migration-log rows, taken the moment the
    /// schema was migrated. Anything that would make a recycled schema
    /// different from a freshly migrated one — a dropped or added table, a new
    /// sequence, a rewritten or deleted migration-log row — changes it, and
    /// `checkIn` then drops the schema, builds a replacement and rethrows so
    /// the test that did it fails. A suite nobody anticipated therefore cannot
    /// quietly poison the pool for everything scheduled after it.
    ///
    /// The check runs BEFORE the deletes so a schema that lost a table is
    /// diagnosed as a fingerprint mismatch rather than as
    /// `relation "…" does not exist` from the sweep.
    private func sweepStatement(for schema: String, on sql: any SQLDatabase) async throws -> String {
        struct NameRow: Decodable { let relname: String }
        struct FingerprintRow: Decodable { let fingerprint: String }

        // `relispartition` keeps a partition out of the list when its parent is
        // already in it; there are none today, and a redundant DELETE would be
        // harmless rather than wrong.
        let tables = try await sql.raw(
            """
            SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = \(bind: schema) AND c.relkind IN ('r', 'p')
               AND NOT c.relispartition AND c.relname <> \(bind: fluentMigrationsTable)
             ORDER BY c.relname
            """
        ).all(decoding: NameRow.self).map(\.relname)

        // DELETE does not reset sequences, so a recycled schema would keep
        // counting up where the last test stopped. That is harmless for a
        // UUID/text identifier and wrong for a serial one, so the pool refuses
        // to recycle a schema that has any sequence at all rather than assume.
        //
        // There are none today, and that is an exhaustive statement rather
        // than a sample: every `@ID` in `Sources/APIServer/Models` is either
        // `@ID(key: .id)` (a client-generated UUID) or
        // `@ID(custom:generatedBy: .user)`, and every `.identifier(` in
        // `Sources/APIServer/Migrations` is `auto: false`. No migration issues
        // raw `CREATE SEQUENCE` and none declares a serial column.
        // `PostgresSchemaPoolTests.noModelUsesADatabaseGeneratedIdentifier`
        // pins that in the source; this asks the database, which is the half
        // that cannot be fooled by a spelling the scan does not know.
        let sequences = try await sql.raw(
            """
            SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = \(bind: schema) AND c.relkind = 'S' ORDER BY c.relname
            """
        ).all(decoding: NameRow.self).map(\.relname)
        guard sequences.isEmpty else {
            throw PostgresSchemaPoolError.databaseGeneratedSequencesFound(sequences)
        }

        let fingerprintQuery = Self.fingerprintQuery(for: schema)
        let fingerprint =
            try await sql.raw("\(unsafeRaw: fingerprintQuery)")
            .first(decoding: FingerprintRow.self)?.fingerprint ?? ""

        // One statement, not one per table, because a plpgsql block runs each
        // statement separately and a foreign key's referential-integrity
        // trigger fires at the end of the STATEMENT that armed it. Emptying 44
        // tables joined by 57 foreign keys one DELETE at a time therefore needs
        // a topological order and breaks on the first cycle; emptying them in
        // one data-modifying `WITH` leaves every integrity check to fire after
        // all of them are already empty, so no order exists to get wrong.
        let sweepDeletes =
            tables
            .enumerated()
            .map { "sweep\($0.offset) AS (DELETE FROM \(qualifiedIdentifier(schema, $0.element)))" }
            .joined(separator: ", ")
        let sweepSQL = tables.isEmpty ? "SELECT 1" : "WITH \(sweepDeletes) SELECT 1"

        return """
            DO $chickadee_pool$
            DECLARE
                -- Prefixed because plpgsql resolves a bare name against its
                -- own variables AND the query's columns, and errors out as
                -- ambiguous when both exist. A variable called `shape` and a
                -- column aliased `shape` is exactly that collision.
                ck_pool_shape text;
            BEGIN
                ck_pool_shape := (\(fingerprintQuery));
                IF ck_pool_shape IS DISTINCT FROM \(quotedLiteral(fingerprint)) THEN
                    RAISE EXCEPTION 'pooled Postgres test schema % came back with a different \
            shape than it was migrated with (tables, sequences or migration-log rows). It has \
            been dropped and rebuilt, so the pool is intact, but the suite that did this must be \
            listed in SchemaMutatingSuites in Tests/APITests/SchemaMutatingSuites.swift so it gets a \
            freshly migrated schema of its own.', \(quotedLiteral(schema));
                END IF;
                EXECUTE \(quotedLiteral(sweepSQL));
            END
            $chickadee_pool$
            """
    }

    /// The md5 of everything about a schema that recycling must preserve: its
    /// relations and its migration-log rows. One expression, used both to
    /// record the fingerprint at migration time and to check it on every
    /// return, so the two cannot drift apart.
    private static func fingerprintQuery(for schema: String) -> String {
        """
        SELECT md5(coalesce(string_agg(shape, chr(10) ORDER BY shape), '')) AS fingerprint
          FROM (SELECT c.relkind::text || ' ' || c.relname AS shape
                  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                 WHERE n.nspname = \(quotedLiteral(schema))
                   AND c.relkind IN ('r', 'p', 'S', 'v', 'm')
                UNION ALL
                SELECT 'migration ' || name
                  FROM \(qualifiedIdentifier(schema, fluentMigrationsTable))) shapes
        """
    }

    // MARK: Maintenance connection

    /// The pool's own Application, used for `CREATE SCHEMA`, the sweeps and the
    /// drops.
    ///
    /// A connection of the pool's own rather than the borrower's, because a
    /// schema is returned AFTER its borrower has shut down — see
    /// `tearDownTestApp`. Sweeping through the borrower would mean sweeping
    /// while its connections are still open, and would not work at all in the
    /// case this has to work in: an application that failed to configure, or
    /// whose connection died mid-test.
    private func maintenanceSQL() async throws -> any SQLDatabase {
        let app = try await maintenanceApplication()
        guard let sql = app.db as? SQLDatabase else { throw PostgresSchemaPoolError.noSQLDatabase }
        return sql
    }

    private func maintenanceApplication() async throws -> Application {
        if let maintenanceTask { return try await maintenanceTask.value }
        guard let settings else { throw PostgresSchemaPoolError.notConfigured }
        let level = logLevel
        // A `Task`, not an `Application?`, for the reentrancy reason spelled
        // out on `MigratedSQLiteTemplate.buildTask`: an `if let` followed by an
        // async build is a window every concurrent first-caller walks through.
        let task = Task { try await Self.makeMaintenanceApplication(settings: settings, logLevel: level) }
        maintenanceTask = task
        do {
            return try await task.value
        } catch {
            maintenanceTask = nil
            throw error
        }
    }

    private static func makeMaintenanceApplication(
        settings: DatabaseSettings, logLevel: Logger.Level
    ) async throws -> Application {
        let app = try await Application.make(.testing)
        do {
            app.logger.logLevel = logLevel
            // One connection per event loop, against the default of 4. This
            // pool issues one short statement at a time and the lane already
            // runs close enough to Postgres's 100-connection cap that the
            // workflow comment explains the parallelization width by it.
            try configureDatabase(
                app, settings: try postgresSettings(settings, searchPath: nil, maxConnectionsPerEventLoop: 1))
            return app
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }
}

/// Drops this process's pooled schemas when the test process exits.
///
/// Without this the pool is a leak in a SHARED database — `capacity` schemas
/// per test process, forever, in exactly the shape `TestAppTempDirectoryTests`
/// exists to catch and that issue #1298 has already cost this project once.
///
/// `atexit` does not run when the process is killed or aborts — a SIGILL from a
/// leaked `Application`, or the CI job-level timeout, both strand the schemas.
/// That is accepted rather than solved, for the same reason the SQLite template
/// accepts it: the CI database lives in a service container that is discarded
/// with the job. The `ck_pool_<tag>` naming is what makes a stranded set
/// identifiable in a developer's long-lived database.
private enum PostgresSchemaPoolCleanup {
    /// A list, not just the shared pool. `MigratedPostgresSchemaPool` is
    /// constructible, so a second one exists the moment a test wants to drive
    /// the mechanism without draining the shared pool — and a cleanup that
    /// knew only about `shared` would leak that one's schemas. The SQLite
    /// template's cleanup keeps a list for the same reason and learned it the
    /// same way: make the cleanup correct independently of how many things
    /// there turn out to be.
    private static let registered = Mutex<[MigratedPostgresSchemaPool]>([])

    static func register(_ pool: MigratedPostgresSchemaPool) {
        let isFirst = registered.withLock { pools -> Bool in
            defer { pools.append(pool) }
            return pools.isEmpty
        }
        guard isFirst else { return }
        atexit { PostgresSchemaPoolCleanup.dropNow() }
    }

    static func dropNow() {
        // `atexit` handlers are synchronous and dropping a schema is not, so
        // the exiting thread waits on the drop. Bounded, because a wedged
        // connection must not turn a finished test run into a hung job — the
        // leak it would prevent is smaller than the failure it would cause.
        let pools = registered.withLock { $0 }
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            for pool in pools { await pool.shutDownAndDropEverything() }
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + 30)
    }
}

/// Quotes an identifier pair for safe interpolation into raw SQL.
private func qualifiedIdentifier(_ schema: String, _ table: String) -> String {
    quotedIdentifier(schema) + "." + quotedIdentifier(table)
}

/// Quotes a string for safe interpolation into raw SQL as a literal. Used only
/// for the pool's generated `DO` block, where a bound parameter is not
/// available because the statement is built once and replayed.
private func quotedLiteral(_ raw: String) -> String {
    "'" + raw.replacingOccurrences(of: "'", with: "''") + "'"
}

/// Fluent's migration-history table. Excluded from the DELETE sweep for the
/// obvious reason — a pooled schema whose history was emptied would look
/// unmigrated to its next borrower — and included in the fingerprint for the
/// less obvious one: a test that REWRITES it has done the damage the sweep
/// cannot undo.
private let fluentMigrationsTable = "_fluent_migrations"
