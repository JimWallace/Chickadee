// Tests/APITests/TestHelpers.swift
//
// Shared helpers for integration tests that involve session auth and CSRF.

import CSRF
import ChickadeeTestSupport
import Core
import Crypto
import Dispatch
import Fluent
import FluentPostgresDriver
import Foundation
import Leaf
import LeafKit
import SQLKit
import Synchronization
import Testing
import VaporTesting

@testable import APIServer

func configureTestDatabase(_ app: Application) async throws {
    // EVERY env read in this function happens inside ONE locked region, and
    // that is load-bearing rather than tidy.
    //
    // `setenv`/`unsetenv` mutate glibc's `environ` in place, and a concurrent
    // `getenv` walking that array is undefined behaviour — not a stale read, a
    // segfault. This helper runs on every one of the suite's ~1,100 test
    // Applications, so it is by far the most frequent env reader in the
    // process; the env WRITERS are a handful of tests that all hold
    // `withAsyncEnvLock` correctly.
    //
    // The `TEST_LOG_LEVEL` read used to sit below, outside this block, and it
    // was the one reader in the codebase that escaped the lock. That is exactly
    // where the parallel run crashed:
    //
    //     Thread 7 crashed: __strlen_evex
    //       specialized _ProcessInfo.environment.getter
    //       static Environment.get(_:)
    //       configureTestDatabase(_:) at TestHelpers.swift:63
    //
    // It presented as a different test dying on each run, which reads as a
    // flake and is not one. Folding the read in here costs nothing — the lock
    // is already being acquired on this line — and is why APITests does not
    // need `--no-parallel`.
    let (settingsFromEnvironment, testLogLevel) = try await withAsyncEnvLock {
        (
            try testDatabaseSettingsFromEnvironment(),
            EnvironmentSource.get("TEST_LOG_LEVEL").flatMap(Logger.Level.init(rawValue:)) ?? .warning
        )
    }
    let settings = settingsFromEnvironment

    // SQLite: copy a once-migrated template instead of migrating again.
    //
    // `autoMigrate` costs 357 ms per application (60 migrations at ~5.9 ms
    // each), measured, and it is ~92 % of what building a test app costs at
    // all. Multiplied by the suite's ~1,100 per-test Applications that is
    // ~390 of the ~660 core-seconds a full `api-tests` run has — roughly 60 %
    // of the lane spent re-deriving a schema that is identical every time.
    //
    // Worse, the cost is a PRODUCT: migrations x applications. Since
    // 2026-05 the migration count went 28 -> 60 and the APITests file count
    // 59 -> 375, so the term grew ~13x while no single change was to blame.
    // Copying a template makes the per-test cost O(1) in the migration count:
    // the next migration anyone writes costs this suite nothing.
    //
    // The copy is a real `.sqlite(path:)` database rather than sqlite-kit's
    // `.memory`, which is itself a temp file on disk — so this swaps one file
    // for another, not memory for disk. Postgres cannot copy a file, so it
    // reaches the same O(1) another way — see the pool below.
    if settings.backend == .sqlite {
        try await configureFromMigratedTemplate(app, logLevel: testLogLevel)
        return
    }

    // Postgres: borrow a pre-migrated schema from the process-wide pool.
    //
    // Same finding as the SQLite template above, measured on this lane: of the
    // 450.6 ms a Postgres test application costs, `autoMigrate` is ~98 %. The
    // file copy has no Postgres analogue — `CREATE DATABASE ... TEMPLATE` was
    // spiked and is only 1.3x cheaper than migrating — but a migrated schema
    // can be EMPTIED and handed to the next test for 1.7 ms, which is 244x.
    // `MigratedPostgresSchemaPool` carries the numbers and the mechanism.
    //
    // A suite that rewrites its schema or its migration log gets one of its
    // own instead; see `SchemaMutatingSuites` for why it cannot share, and for
    // the two guards that keep that list honest.
    if SchemaMutatingSuites.currentTestMutatesItsSchema {
        try await configureWithFreshlyMigratedPostgresSchema(
            app, settings: settings, logLevel: testLogLevel)
        return
    }

    let lease = try await MigratedPostgresSchemaPool.shared.checkOut(
        settings: settings, logLevel: testLogLevel)
    // Recorded BEFORE anything else that can throw. `makeTestingApplication`
    // tears a half-built application down on throw and teardown is what
    // returns the lease — so a failure between here and the end of this
    // function has to be able to find it already.
    app.storage[PooledPostgresSchemaKey.self] = lease
    try configureDatabase(
        app, settings: try postgresSettings(settings, searchPath: [lease.schemaName]))

    // Registering is NOT the expensive part — running is; and it is
    // load-bearing for exactly the reason the SQLite template path records
    // below. Six suites call `autoMigrate()` themselves and rely on it being a
    // clean no-op against a complete migration log, which an empty registry
    // would silently turn into "do nothing".
    registerMigrations(on: app)
}

/// Migrates a private schema for this application, the way every Postgres test
/// application used to.
///
/// Kept for the suites that cannot share a recycled schema. ~450 ms per
/// application slower, and correct for a test that rewrites the schema or the
/// migration log, because nothing else ever sees this one — `tearDownTestApp`
/// drops it.
private func configureWithFreshlyMigratedPostgresSchema(
    _ app: Application, settings: DatabaseSettings, logLevel: Logger.Level
) async throws {
    // Per-test isolated schema so tests can run concurrently against one shared
    // database. Each `Application` gets its own schema + `search_path`, so
    // migrations and queries on one app can't trample another. Replaces the old
    // `DROP SCHEMA public CASCADE; CREATE SCHEMA public` reset.
    let schemaName = "test_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12))"
    app.storage[TestPostgresSchemaKey.self] = schemaName
    try configureDatabase(app, settings: try postgresSettings(settings, searchPath: [schemaName]))
    try await createPostgresTestSchema(app, schemaName: schemaName)
    registerMigrations(on: app)

    // FluentKit logs two info lines per migration ("Starting/Finished prepare").
    // Across the API suite's ~1,100 per-test Applications × 50+ migrations that
    // is >120k log lines that bury real test failures in CI output. Quiet just
    // the migration burst — the test body keeps its normal level (restored
    // below), so nothing that inspects warnings/errors (the query_logs / ring
    // buffer tests) is affected. Override the floor with TEST_LOG_LEVEL (e.g.
    // =info) when debugging migrations.
    let priorLogLevel = app.logger.logLevel
    app.logger.logLevel = logLevel
    try await app.autoMigrate()
    app.logger.logLevel = priorLogLevel
}

/// Rebuilds Postgres settings with a different `search_path`, and optionally a
/// different pool size.
///
/// Test-side only: `DatabaseSettings` is production code and this change adds
/// nothing to it, the same way the SQLite template reused an existing
/// `DatabaseSettings.sqlite(path:)`.
func postgresSettings(
    _ settings: DatabaseSettings,
    searchPath: [String]?,
    maxConnectionsPerEventLoop: Int? = nil
) throws -> DatabaseSettings {
    guard
        let host = settings.postgresHost,
        let port = settings.postgresPort,
        let database = settings.postgresDatabase,
        let username = settings.postgresUsername,
        let password = settings.postgresPassword
    else {
        throw DatabaseConfigurationError.invalidSettings("Postgres test settings are incomplete.")
    }
    return .postgres(
        host: host,
        port: port,
        database: database,
        username: username,
        password: password,
        searchPath: searchPath,
        maxConnectionsPerEventLoop: maxConnectionsPerEventLoop
    )
}

struct TestPostgresSchemaKey: StorageKey {
    typealias Value = String
}

/// The per-test SQLite file copied from the migrated template, so teardown can
/// remove it. Distinct from the `sqlite-kit_memorydb-*` files `.memory` leaves
/// behind — both are cleaned, because a suite that opts out of the template
/// (or a toolchain that changes sqlite-kit's behaviour) still produces those.
struct TestSQLiteDatabaseFileKey: StorageKey {
    typealias Value = String
}

/// Removes the process's template database when the test process exits.
///
/// Without this the template is a leak — one file per test process, forever,
/// which is the shape of defect `TestAppTempDirectoryTests` exists to catch
/// and that issue #1298 already cost this project once. It is small (a schema
/// with no rows) where #1298's was 1.4 GB, but "small leak" is still the
/// argument that lost last time.
///
/// `atexit` does not run when the process is killed or aborts — a SIGILL from
/// a leaked `Application`, or the CI job-level timeout, both strand the file.
/// That is accepted rather than solved: those paths strand the whole temp tree
/// anyway, and the runner is discarded after the job.
private enum SQLiteTemplateCleanup {
    /// A list, not a single path. The builder above is meant to produce exactly
    /// one template per process, but a cleanup that can only remember the last
    /// path registered would quietly leak the rest if that ever stopped being
    /// true — and it already did once (actor reentrancy, see above). Tracking
    /// everything registered makes the cleanup correct independently of the
    /// builder being correct.
    private static let registered = Mutex<[String]>([])

    static func register(_ path: String) {
        let isFirst = registered.withLock { paths -> Bool in
            defer { paths.append(path) }
            return paths.isEmpty
        }
        guard isFirst else { return }
        atexit { SQLiteTemplateCleanup.removeNow() }
    }

    static func removeNow() {
        for path in registered.withLock({ $0 }) {
            for suffix in ["", "-journal", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }
    }
}

/// Builds the migrated SQLite template once per test process, then hands out
/// copies of it.
///
/// An actor because the first caller pays for the whole migration run and
/// every other concurrent test must wait for that one result rather than
/// racing to build its own. After that the cost is a file copy.
private actor MigratedSQLiteTemplate {
    static let shared = MigratedSQLiteTemplate()

    /// The single build, shared by every caller.
    ///
    /// Storing a `Task` rather than a `String?` is what makes this build ONCE.
    /// Actors are reentrant across `await`, so a plain `if let builtPath` guard
    /// followed by an async build has a window every concurrent first-caller
    /// walks through: each sees nil, each builds its own template. That is not
    /// theoretical — it shipped in the first draft of this file and showed up
    /// as THREE template files left in the temp directory after a single run,
    /// which is also three times the one-off migration cost. Assigning the task
    /// before the first suspension closes the window; later callers await the
    /// same task and get the same path.
    private var buildTask: Task<String, Error>?

    /// Path to the template database, building it on first call.
    func templatePath(logLevel: Logger.Level) async throws -> String {
        if let buildTask { return try await buildTask.value }
        let task = Task { try await Self.build(logLevel: logLevel) }
        buildTask = task
        do {
            return try await task.value
        } catch {
            // A failed build must not poison every later caller with the same
            // error — the next one retries.
            buildTask = nil
            throw error
        }
    }

    private static func build(logLevel: Logger.Level) async throws -> String {
        let path =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-migrated-template-\(UUID().uuidString).sqlite")
            .path
        let app = try await Application.make(.testing)
        do {
            try configureDatabase(app, settings: .sqlite(path: path))
            registerMigrations(on: app)
            // Same log-level squelch as the old per-app path, for the same
            // reason — except now it happens once instead of ~1,100 times.
            let priorLogLevel = app.logger.logLevel
            app.logger.logLevel = logLevel
            try await app.autoMigrate()
            app.logger.logLevel = priorLogLevel
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            try? FileManager.default.removeItem(atPath: path)
            throw error
        }
        SQLiteTemplateCleanup.register(path)
        return path
    }
}

/// Points `app` at a fresh copy of the migrated template.
///
/// No `autoMigrate` runs here: the copy already carries the schema AND the
/// populated `_fluent_migrations` table, so Fluent sees every migration as
/// applied. That matters beyond speed — the suites that call `autoMigrate()`
/// themselves (MigrationNamespaceReconcilerTests and five others) rely on a
/// second call being a clean no-op, which is exactly what a complete
/// migration log makes it.
private func configureFromMigratedTemplate(_ app: Application, logLevel: Logger.Level) async throws {
    let template = try await MigratedSQLiteTemplate.shared.templatePath(logLevel: logLevel)
    let copy =
        FileManager.default.temporaryDirectory
        .appendingPathComponent("chickadee-testdb-\(UUID().uuidString).sqlite")
        .path
    try FileManager.default.copyItem(atPath: template, toPath: copy)
    app.storage[TestSQLiteDatabaseFileKey.self] = copy
    try configureDatabase(app, settings: .sqlite(path: copy))

    // Registering is NOT the expensive part — running is. `registerMigrations`
    // builds a list; `autoMigrate` executes 60 statements against a fresh file.
    // So the registry still goes on, and only the execution is skipped.
    //
    // It is also load-bearing rather than tidy. Six suites call `autoMigrate()`
    // themselves, and `MigrationNamespaceReconcilerTests` does the sharpest
    // version: it reverts CreateSweepLeases, deletes its history row, and
    // requires `autoMigrate` to apply exactly that one migration forward. With
    // an empty registry that call silently does nothing and the test fails on
    // `no such table: sweep_leases` — which is how this omission was caught.
    registerMigrations(on: app)
}

/// Quotes an identifier for safe interpolation into raw SQL.  Test schema
/// names are generated from a UUID so they shouldn't contain `"` themselves,
/// but escape anyway — defense in depth, no perf cost.
private func quotedIdentifier(_ raw: String) -> String {
    "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

private func createPostgresTestSchema(_ app: Application, schemaName: String) async throws {
    guard let sql = app.db as? SQLDatabase else { return }
    // CREATE SCHEMA is global and doesn't depend on search_path, so this
    // runs cleanly even though the freshly-configured connection has its
    // search_path pointing at the not-yet-existent schema.
    let quoted = quotedIdentifier(schemaName)
    try await sql.raw("CREATE SCHEMA \(unsafeRaw: quoted)").run()
}

func dropPostgresTestSchema(_ app: Application) async throws {
    guard let schemaName = app.storage[TestPostgresSchemaKey.self] else { return }
    guard let sql = app.db as? SQLDatabase else { return }
    let quoted = quotedIdentifier(schemaName)
    try await sql.raw("DROP SCHEMA IF EXISTS \(unsafeRaw: quoted) CASCADE").run()
}

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

/// Suites that change their database's SHAPE, and therefore must not be given
/// a recycled schema.
///
/// Two kinds of change, one consequence. `MigrationNamespaceReconcilerTests`
/// rewrites the Fluent migration log: it reverts `CreateSweepLeases`, deletes
/// that migration's history row, renames every other row into a legacy
/// namespace and calls `autoMigrate()` to put it all back.
/// `MCPAuditFailClosedTests` drops the `audit_log` table outright, to prove a
/// write tool fails closed when its audit record cannot persist.
/// `ResultCollectionBackfillMigrationTests` builds a legacy-shaped schema with
/// raw DDL. All three are exactly right against a schema they own, and all
/// three would leave a pooled schema different from a freshly migrated one —
/// a corruption that surfaces as unrelated tests failing on a missing table,
/// several files away from the cause.
///
/// (The third is declared and inert: it configures its own bare
/// `.sqliteInMemory()` application and never calls `configureTestDatabase`, so
/// it never asks the pool for anything. It is listed because the scan below
/// flags what it DOES, and a list that disagreed with the scan would be a list
/// somebody edits the scan to silence.)
///
/// **Naming a suite is the brittle half of this design, and this file already
/// records why**: "a guard pointed at a mechanism by name is a guard that
/// changing the mechanism silently empties" (ci-flakiness Family 5, attack
/// note 5). So the names are not trusted on their own. Two guards stand behind
/// them and NEITHER knows any of them:
///
///   * `PostgresSchemaPoolTests.everySchemaMutatingSuiteIsDeclared` scans
///     `Tests/APITests/` for suites that touch the migration log or issue DDL,
///     and fails if the set it finds differs from this one. Renaming a suite,
///     splitting it, or writing a new one is then a red test naming the
///     missing suite — not a silent hole.
///   * The pool fingerprints every schema on the way back in (see
///     `MigratedPostgresSchemaPool.sweepStatement(for:on:)`). A schema whose
///     tables, sequences or migration log changed while it was on loan is
///     dropped and rebuilt, and the borrowing test's teardown throws. That
///     guard is keyed on the damage rather than on who did it, so it holds for
///     a suite nobody thought of.
///
/// The second guard is not theoretical: `MCPAuditFailClosedTests` is in this
/// list because the fingerprint caught it on the first full run, having been
/// missed by a hand search that forgot to recurse into `Tests/APITests/MCP/`.
enum SchemaMutatingSuites {
    static let names: Set<String> = [
        "MigrationNamespaceReconcilerTests",
        "MCPAuditFailClosedTests",
        "ResultCollectionBackfillMigrationTests",
        "GetValidationResultVariantFallbackTests",
    ]

    /// True when the test currently running belongs to one of those suites.
    ///
    /// `Test.current` is nil outside a test body — the pool's own builder
    /// applications, for one — and "not running inside a test" mutates
    /// nobody's schema.
    static var currentTestMutatesItsSchema: Bool {
        guard let test = Test.current else { return false }
        return !names.isDisjoint(with: test.id.nameComponents)
    }
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
/// as the SQLite template note above): `Application.make` + shutdown is 0.9 ms,
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
            listed in SchemaMutatingSuites in Tests/APITests/TestHelpers.swift so it gets a \
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

func testDatabaseSettingsFromEnvironment() throws -> DatabaseSettings {
    let backend =
        EnvironmentSource.get("TEST_DATABASE_BACKEND")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .flatMap(DatabaseBackend.init(rawValue:))
        ?? .sqlite

    switch backend {
    case .sqlite:
        return .sqliteInMemory()
    case .postgres:
        let host = EnvironmentSource.get("TEST_DATABASE_HOST")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let database = EnvironmentSource.get("TEST_DATABASE_NAME")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = EnvironmentSource.get("TEST_DATABASE_USER")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = EnvironmentSource.get("TEST_DATABASE_PASSWORD")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = EnvironmentSource.get("TEST_DATABASE_PORT")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : Int($0) }

        guard
            let host, !host.isEmpty,
            let database, !database.isEmpty,
            let username, !username.isEmpty,
            let password, !password.isEmpty,
            let port
        else {
            var missing: [String] = []
            if host?.isEmpty != false { missing.append("TEST_DATABASE_HOST") }
            if port == nil { missing.append("TEST_DATABASE_PORT") }
            if database?.isEmpty != false { missing.append("TEST_DATABASE_NAME") }
            if username?.isEmpty != false { missing.append("TEST_DATABASE_USER") }
            if password?.isEmpty != false { missing.append("TEST_DATABASE_PASSWORD") }

            throw DatabaseConfigurationError.invalidSettings(
                "TEST_DATABASE_BACKEND=postgres requires: \(missing.joined(separator: ", "))"
            )
        }

        return .postgres(
            host: host,
            port: port,
            database: database,
            username: username,
            password: password
        )
    }
}

// MARK: - Course fixture helper

private struct TestCourseIDsKey: StorageKey {
    typealias Value = [String: UUID]
}

extension Application {
    /// Returns the UUID of a test `APICourse` with `code`, creating it on first
    /// call.  Memoized per `Application` in `storage` so repeat callers don't
    /// re-query the database.  Six test classes previously each carried a
    /// private copy of this helper; consolidating here matches the same
    /// drift-avoidance rationale as `makeTestApp` / `registerMigrations`.
    func testCourseID(
        code: String = "TEST101",
        name: String = "Test Course",
        enrollmentMode: CourseEnrollmentMode = .open
    ) async throws -> UUID {
        if let cached = storage[TestCourseIDsKey.self]?[code] {
            return cached
        }
        let course: APICourse
        if let existing = try await APICourse.query(on: db).filter(\.$code == code).first() {
            course = existing
        } else {
            course = APICourse(code: code, name: name, enrollmentMode: enrollmentMode)
            try await course.save(on: db)
        }
        let id = try course.requireID()
        var cache = storage[TestCourseIDsKey.self] ?? [:]
        cache[code] = id
        storage[TestCourseIDsKey.self] = cache
        return id
    }
}

/// Enrols `username` as a per-course instructor in the shared TEST101 course so
/// the per-course `/instructor` gate (Phase 5) admits them. Idempotent.
func enrollAsTestInstructor(
    username: String, on app: Application, courseCode: String = "TEST101"
) async throws {
    let courseID = try await app.testCourseID(code: courseCode)
    guard let user = try await APIUser.query(on: app.db).filter(\.$username == username).first()
    else { return }
    let userID = try user.requireID()
    // Upsert to `.instructor` — a `.auto` course auto-enrolls the user at login
    // and (post role-collapse, #417 Slice G2) seeds a non-admin as a per-course
    // `.student`, so skipping on "already enrolled" could leave them a student
    // and 403 the per-course staff gates.
    if let existing = try await APICourseEnrollment.query(on: app.db)
        .filter(\.$userID == userID).filter(\.$course.$id == courseID).first()
    {
        if existing.role != .instructor {
            existing.role = .instructor
            try await existing.save(on: app.db)
        }
    } else {
        try await APICourseEnrollment(userID: userID, courseID: courseID, role: .instructor)
            .save(on: app.db)
    }
}

/// Demotes every one of `username`'s course enrollments to `.student` — the
/// per-course equivalent of the retired "downgrade the global role" move (#417
/// Slice G2 collapsed the deployment role to user/admin/mcp, so teaching
/// authority lives on the enrollment). After this the user is staff nowhere, so
/// MCP content consent / refresh re-authorization (`isStaffAnywhere`) must fail.
func demoteToStudentEverywhere(username: String, on app: Application) async throws {
    guard let user = try await APIUser.query(on: app.db).filter(\.$username == username).first()
    else { return }
    let userID = try user.requireID()
    for enrollment in try await APICourseEnrollment.query(on: app.db)
        .filter(\.$userID == userID).all()
    {
        enrollment.role = .student
        try await enrollment.save(on: app.db)
    }
}

// MARK: - Async app lifecycle

/// Runs an async test body with a Vapor application and always tears it down:
/// shutdown plus removal of any temp state the harness created for it (the
/// `makeTestApp` directory tree, the file sqlite-kit secretly backs an
/// "in-memory" database with, the per-test Postgres schema). Safe for bare
/// apps too — each cleanup step is a no-op when there is nothing to clean.
///
/// It is also where APITests arms `WedgeWatchdog`. This is the target's one
/// universal test-body scope — 172 of its 315 files call it directly, about
/// two-thirds of the target's tests, and `withWebRoutesApp` /
/// `withAssignmentRoutesApp` funnel into it — so wrapping it means every test
/// that starts or finishes resets the stall clock, and the watchdog stays
/// armed exactly while test bodies are in flight. `.timeLimit`, which 33
/// APITests files carry, cannot do this job: the trait needs a
/// cooperative-pool thread to fire, and pool saturation is the failure being
/// watched for (#1233; ci-flakiness Family 5).
func withApp(_ app: Application, _ body: (Application) async throws -> Void) async throws {
    try await WedgeWatchdog.track {
        // Teardown runs EXACTLY ONCE, however the body ends.
        //
        // This used to be `do { body; tearDown } catch { tearDown; throw }`,
        // which tears down twice when the tear-down in the `do` is the thing
        // that throws — and a second `tearDownTestApp` on an application that
        // is already shut down is not an error, it is
        // `Vapor/Core.swift: Fatal error: Core not configured`, which takes
        // the whole test PROCESS with it. Nothing made teardown throw before
        // the schema pool did, so the latent path was never walked; the
        // pool's check-in can throw, and it walked it on the first full run.
        var failure: (any Error)?
        do { try await body(app) } catch { failure = error }
        do { try await app.tearDownTestApp() } catch { failure = failure ?? error }
        if let failure { throw failure }
    }
}

/// Creates a `.testing` Vapor Application and runs `setup`, returning the
/// fully-configured app to the caller.  If `setup` throws, the partial
/// Application is torn down before the error is rethrown.
///
/// This is the safe replacement for the bare pattern
///
///     let app = try await Application.make(.testing)
///     /* setup that may throw */
///     return app
///
/// which leaks a half-built `Application` on throw.  `Application.deinit`
/// then calls the *synchronous* `shutdown()`, and on a testing app with
/// NIO event loops + FluentKit pools that trips an assertion in
/// `ServeCommand.deinit` → SIGILL on Linux.  That terminates the whole
/// xctest process and kills every other concurrent test.
func makeTestingApplication(
    setup: (Application) async throws -> Void
) async throws -> Application {
    let app = try await Application.make(.testing)
    do {
        try await setup(app)
        return app
    } catch {
        // Full teardown, not just shutdown: `setup` may have configured a
        // database (and thereby materialized sqlite-kit's fake-memory temp
        // file) before throwing.
        try? await app.tearDownTestApp()
        throw error
    }
}

// MARK: - Standard test app

private struct TestDataDirectoryKey: StorageKey {
    typealias Value = String
}

private struct LeafViewsSymlinkKey: StorageKey {
    typealias Value = String
}

extension Application {
    /// Filesystem directory created for this app's results/testsetups/
    /// submissions trees; `tearDownTestApp` removes it. `makeTestApp` sets it;
    /// suites that build a bespoke tree instead (e.g. a fake working
    /// directory) should record it here so their `withApp` teardown removes
    /// the tree too. Nil for apps with no on-disk state.
    var testDataDirectory: String? {
        get { storage[TestDataDirectoryKey.self] }
        set { storage[TestDataDirectoryKey.self] = newValue }
    }

    /// The on-disk files secretly backing this app's "in-memory" SQLite
    /// databases. Usually zero (postgres lane, no database) or one; a test
    /// that registers a second in-memory pool (e.g. a stand-in `.mcp` pool)
    /// has two.
    ///
    /// sqlite-kit fakes `.memory` storage with a real file in the system temp
    /// directory — SQLiteNIO is built with `SQLITE_OMIT_SHARED_CACHE`, so it
    /// cannot offer genuinely shared in-memory databases — and acknowledges in
    /// a comment that the file outlives the last connection. Nothing upstream
    /// ever deletes it, so each per-test Application leaks one ~600 KB file
    /// (#1298: ~973 MB per full suite run). We ask SQLite itself for the path
    /// (`PRAGMA database_list`) rather than mirroring sqlite-kit's private
    /// filename scheme, then accept only files that scheme plainly produced —
    /// so a real `.file(path:)` database can never be swept up, even one that
    /// happens to live in the temp directory.
    func sqliteFakeMemoryDatabaseFiles() async -> [String] {
        struct DatabaseListRow: Decodable {
            let name: String
            let file: String
        }
        let systemTempDir = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath().path
        var files: [String] = []
        for id in databases.ids() {
            // Dialect metadata is static — checking it opens no connection, so
            // a registered-but-unreachable Postgres pool costs nothing here.
            guard let sql = db(id) as? SQLDatabase, sql.dialect.name == "sqlite" else { continue }
            guard
                let rows = try? await sql.raw("PRAGMA database_list")
                    .all(decoding: DatabaseListRow.self)
            else { continue }
            for row in rows where row.name == "main" {
                let file = URL(fileURLWithPath: row.file).resolvingSymlinksInPath()
                guard
                    file.lastPathComponent.hasPrefix("sqlite-kit_memorydb-"),
                    file.path.hasPrefix(systemTempDir)
                else { continue }
                files.append(file.path)
            }
        }
        return files
    }

    /// Every real file backing this app's SQLite databases, whichever mechanism
    /// put it there: the migrated-template copy that `configureTestDatabase`
    /// hands out, or sqlite-kit's fake-memory file for an app configured with
    /// `.sqliteInMemory()` directly.
    ///
    /// The leak guards assert against THIS rather than against either
    /// mechanism, so that changing how a test database is materialized moves
    /// one function instead of silently emptying the guard's input — which is
    /// exactly what introducing the template did to it the first time.
    func sqliteDatabaseFilesOnDisk() async -> [String] {
        var files = await sqliteFakeMemoryDatabaseFiles()
        if let templateCopy = storage[TestSQLiteDatabaseFileKey.self] {
            files.append(templateCopy)
        }
        return files
    }

    /// Tears the app down completely: drops the per-test Postgres schema (if
    /// any), shuts the app down, and removes every piece of temp state created
    /// on its behalf — the `makeTestApp` directory tree, sqlite-kit's
    /// fake-memory database files, and the Leaf views symlink. Every step is a
    /// no-op when there is nothing to clean, so this is safe for any test app
    /// however it was built. `withApp` calls this; use it directly only for
    /// apps whose lifecycle `withApp` doesn't own.
    func tearDownTestApp() async throws {
        // Collect everything that needs a live app before shutting down.
        let dir = storage[TestDataDirectoryKey.self]
        let leafSymlink = storage[LeafViewsSymlinkKey.self]
        let sqliteFiles = await sqliteFakeMemoryDatabaseFiles()
        let templateCopy = storage[TestSQLiteDatabaseFileKey.self]
        let pooledSchema = storage[PooledPostgresSchemaKey.self]
        try? await dropPostgresTestSchema(self)

        // Shut down, return the pooled schema, clean the temp state — and do
        // ALL THREE whatever happens to the ones before them.
        //
        // This used to be `try await asyncShutdown()` with the cleanup below
        // it, so a throwing shutdown skipped every removal. That was already a
        // small leak; with a pool behind it, it is the failure mode that takes
        // the whole run down: a schema never returned is capacity the pool
        // never gets back, and the fourth test to lose one blocks every test
        // after it until the checkout timeout. So the first error is held and
        // rethrown at the end instead of short-circuiting the rest.
        //
        // The return happens AFTER the shutdown, deliberately: a schema is
        // back in the pool only once the application that borrowed it has no
        // connections left that could still write to it.
        var firstError: (any Error)?
        do { try await asyncShutdown() } catch { firstError = error }
        if let pooledSchema {
            do {
                try await MigratedPostgresSchemaPool.shared.checkIn(pooledSchema)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let templateCopy {
            // Same sidecar sweep as below: a crash mid-test can strand a
            // journal even though the default rollback journal is transient.
            for path in [templateCopy, templateCopy + "-journal", templateCopy + "-wal", templateCopy + "-shm"] {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        if let dir {
            try? FileManager.default.removeItem(atPath: dir)
        }
        for file in sqliteFiles {
            // The fake-memory databases run the default rollback journal, so
            // the sidecars exist only transiently — but removal is cheap and a
            // crash can strand them.
            for path in [file, file + "-journal", file + "-wal", file + "-shm"] {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        if let leafSymlink {
            try? FileManager.default.removeItem(atPath: leafSymlink)
        }
        if let firstError { throw firstError }
    }
}

/// Builds a `.testing` Vapor application with the standard test wiring:
/// per-app temp directories for results/testsetups/submissions,
/// in-memory sessions, the production migration list, Leaf views, and
/// the full route tree mounted.
///
/// Caller owns the lifecycle — wrap the test body in `withApp(app) { ... }`
/// (which tears the app down, temp state included) or pair the call with
/// `app.tearDownTestApp()`.  For unit tests that need a bare app
/// (single-middleware isolation, custom auth modes, custom database
/// configuration), use `Application.make(.testing)` directly.
func makeTestApp(
    prefix: String = "chickadee-test",
    authMode: AuthMode = .local,
    appConfig: AppConfig? = nil
) async throws -> Application {
    try await makeTestingApplication { app in
        app.authMode = authMode
        // Seed AppConfig so code that reads `app.appConfig.<sub>` (e.g.
        // workerJobRoutes' public-base-URL resolver, OIDC redirect builder) sees
        // sane defaults during integration tests. Callers can pass a custom
        // `appConfig` to exercise specific config branches.
        app.appConfig = appConfig ?? AppConfig.testDefaults(authMode: authMode)

        // The trailing slash is applied AFTER `.path`, not before. `URL.path`
        // strips a trailing slash, so building it into the path component left
        // `tmpDir` as `/tmp/<prefix>-<uuid>` and made every concatenation below
        // a SIBLING of that directory rather than a child
        // (`/tmp/<prefix>-<uuid>content-files/`). Nothing then created
        // `tmpDir` itself, so `tearDownTestApp`'s `removeItem` was deleting a
        // path that never existed — silently, under its `try?` — and every run
        // leaked ~1.4 GB across ~6,900 entries. See issue #1298.
        let tmpDir =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
            .path + "/"
        let dirs = ["results/", "testsetups/", "submissions/", "data-exports/", "content-files/"].map {
            tmpDir + $0
        }
        for dir in dirs {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        app.resultsDirectory = dirs[0]
        app.testSetupsDirectory = dirs[1]
        app.submissionsDirectory = dirs[2]
        app.dataExportsDirectory = dirs[3]
        app.contentFilesDirectory = dirs[4]
        // Seed the worker-secret and local-runner-autostart paths into the
        // per-test temp directory so admin/worker-management tests don't
        // collide with each other or with the dev .worker-secret on disk.
        app.workerSecretFilePath = tmpDir + ".worker-secret"
        app.localRunnerAutoStartFilePath = tmpDir + ".local-runner-autostart"
        app.storage[TestDataDirectoryKey.self] = tmpDir

        app.sessions.use(.memory)
        app.middleware.use(app.sessions.middleware)

        try await configureTestDatabase(app)

        // Assignment content-version capture. Registered here rather than
        // inherited from `bootstrapAppMiddleware` (which the test app does not
        // run) because versioning is part of what the instructor write routes
        // DO, not an ambient production-only concern — a test app that skips it
        // would let a capture regression pass CI unnoticed.
        // `AssignmentVersionCaptureWiringTests` pins the production
        // registration separately.
        app.middleware.use(AssignmentVersionCaptureMiddleware())

        // The browser-grading import check's inventory, loaded here for the same
        // reason the version-capture middleware is registered above: rejecting a
        // script whose imports the grading kernel lacks is part of what the
        // instructor write routes DO, so a test app without it would let a
        // regression through. Silently absent when the vendored kernel bytes are
        // not in the checkout, matching production (`bootstrapAppServices`).
        app.kernelEnvironments = KernelEnvironments.load(
            publicDirectory: app.directory.publicDirectory)

        configureLeaf(app)
        try routes(app)
    }
}

extension Application {
    @discardableResult
    func asyncTest(
        method runnerMethod: Method = .inMemory,
        _ method: HTTPMethod,
        _ path: String,
        headers: HTTPHeaders = [:],
        body: ByteBuffer? = nil,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column,
        afterResponse: (TestingHTTPResponse) throws -> Void
    ) async throws -> TestingApplicationTester {
        try await self.asyncTest(
            method: runnerMethod,
            method,
            path,
            headers: headers,
            body: body,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column,
            beforeRequest: { _ in },
            afterResponse: afterResponse
        )
    }

    @discardableResult
    func asyncTest(
        method runnerMethod: Method = .inMemory,
        _ method: HTTPMethod,
        _ path: String,
        headers: HTTPHeaders = [:],
        body: ByteBuffer? = nil,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column,
        beforeRequest: (inout TestingHTTPRequest) throws -> Void = { _ in },
        afterResponse: (TestingHTTPResponse) throws -> Void = { _ in }
    ) async throws -> TestingApplicationTester {
        let tester = try self.testing(method: runnerMethod)
        return try await tester.test(
            method,
            path,
            headers: headers,
            body: body,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column,
            beforeRequest: { request async throws in
                try beforeRequest(&request)
            },
            afterResponse: { response async throws in
                try afterResponse(response)
            }
        )
    }

    /// Fire a request and return the response directly, without a callback.
    /// Useful for concurrent tests where multiple responses must be collected.
    func asyncSendRequest(
        _ method: HTTPMethod,
        _ path: String,
        headers: HTTPHeaders = [:],
        body: ByteBuffer? = nil,
        beforeRequest: (inout TestingHTTPRequest) throws -> Void = { _ in }
    ) async throws -> TestingHTTPResponse {
        var captured: TestingHTTPResponse?
        try await self.asyncTest(
            method, path,
            headers: headers,
            body: body,
            beforeRequest: beforeRequest,
            afterResponse: { captured = $0 }
        )
        return try #require(captured)
    }
}

// MARK: - Leaf / CSRF setup

/// Call in test setUp — after session middleware, before routes() — to enable
/// Leaf rendering. Required so that GET requests to form pages produce HTML
/// containing the `#csrfFormField()` hidden input, which is how tests obtain
/// a valid session-bound CSRF token.
func configureLeaf(_ app: Application) {
    // LeafKit's sandbox rejects any path that contains a hidden directory component
    // (e.g. ".claude"). When running from a git worktree under .claude, create a
    // symlink from a clean temp path so the string-level path checks pass.
    let viewsDir = app.directory.viewsDirectory
    if viewsDir.contains("/.") {
        let cleanPath = NSTemporaryDirectory() + "chickadee-leaf-\(UUID().uuidString)"
        try? FileManager.default.removeItem(atPath: cleanPath)
        try? FileManager.default.createSymbolicLink(atPath: cleanPath, withDestinationPath: viewsDir)
        app.leaf.configuration = LeafConfiguration(rootDirectory: cleanPath + "/")
        // Recorded so tearDownTestApp removes the symlink — one per app adds
        // up across a worktree session (#1298's leak class, in miniature).
        app.storage[LeafViewsSymlinkKey.self] = cleanPath
    }
    app.views.use(.leaf)
    app.leaf.tags["csrfFormField"] = CSRFFormFieldTag()
    // rawJSON is safe to register in tests (pure string passthrough).
    // csrfToken / appVersion are intentionally NOT registered here — they
    // trigger CSRF.createToken / version lookups that assume a more complete
    // middleware stack than the minimal test app.  Pages that embed
    // `#csrfToken()` or `#appVersion()` will render those tokens verbatim;
    // no existing test asserts on that markup.
    app.leaf.tags["rawJSON"] = RawJSONTag()
    // Safe in the minimal test app: reads only securityConfiguration, which
    // falls back to `.default` (30 min) when unset.
    app.leaf.tags["sessionIdleTimeoutSeconds"] = SessionIdleTimeoutTag()
    app.leaf.tags["sessionIdleWarningSeconds"] = SessionIdleWarningTag()
}

// MARK: - CSRF token extraction

/// Parses the CSRF token from a rendered Leaf form page.
/// Looks for the hidden input rendered by `#csrfFormField()`:
///   `<input type='hidden' name='_csrf' value='TOKEN'>`
func extractCSRFToken(from html: String) -> String {
    guard let range = html.range(of: "name='_csrf' value='") else { return "" }
    let start = range.upperBound
    guard let end = html[start...].firstIndex(of: "'") else { return "" }
    return String(html[start..<end])
}

/// GETs `path` and returns the CSRF token embedded in the rendered form HTML,
/// along with the session cookie (creating one on first call, or reusing the
/// supplied `cookie` to stay in the same session).
func csrfFields(
    for path: String,
    cookie: String = "",
    on app: Application
) async throws -> (token: String, cookie: String) {
    var outToken = ""
    var outCookie = cookie
    try await app.asyncTest(
        .GET, path,
        beforeRequest: { req in
            if !cookie.isEmpty { req.headers.add(name: .cookie, value: cookie) }
        },
        afterResponse: { res in
            if let c = res.headers.first(name: .setCookie) { outCookie = c }
            outToken = extractCSRFToken(from: res.body.string)
        })
    return (outToken, outCookie)
}

// MARK: - Worker HMAC auth helper

/// Generates HMAC-signed HTTPHeaders for worker requests in tests.
/// Produces the same signature that WorkerHMACAuthMiddleware expects.
func workerHMACHeaders(
    method: HTTPMethod,
    path: String,
    body: ByteBuffer? = nil,
    workerSecret: String,
    workerID: String = "test-runner"
) -> HTTPHeaders {
    let timestamp = Int64(Date().timeIntervalSince1970)
    let nonce = UUID().uuidString

    var bodyCopy = body ?? ByteBuffer()
    let bodyBytes = bodyCopy.readBytes(length: bodyCopy.readableBytes) ?? []
    let bodyHash = Data(SHA256.hash(data: Data(bodyBytes))).hexEncodedString()

    let payload = [
        method.rawValue.uppercased(),
        path,
        bodyHash,
        String(timestamp),
        nonce,
    ].joined(separator: "\n")

    let key = SymmetricKey(data: Data(workerSecret.utf8))
    let mac = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
    let signature = Data(mac).hexEncodedString()

    var headers = HTTPHeaders()
    headers.add(name: "X-Worker-Timestamp", value: String(timestamp))
    headers.add(name: "X-Worker-Nonce", value: nonce)
    headers.add(name: "X-Worker-Body-SHA256", value: bodyHash)
    headers.add(name: "X-Worker-Signature", value: signature)
    headers.add(name: "X-Worker-Id", value: workerID)
    headers.contentType = .json
    return headers
}

private extension Data {
    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Login helper

/// Hashes a password at the minimum bcrypt cost (4) for test fixtures.
///
/// Production hashing uses the default cost (12, ~150 ms). Test security is
/// irrelevant, but running a cost-12 hash + verify for every login across the
/// parallel suite saturates the CI runner (a 4-CPU box with no quota, measured
/// 2026-09-16 by the StarvationRecorder arming line; it was 2 cores when this
/// was written) — under the nightly coverage
/// build that CPU starvation slows test-app/login setup enough to flake
/// auth-dependent tests (303/401 / ~80 s stalls). bcrypt verify reads the cost
/// from the stored hash, so logins against these fixtures are fast too.
///
/// This only changes *test fixture* hashes. It does NOT touch the app's
/// configured password hasher, so `LocalAuthProvider`'s timing-equalizer (the
/// account-enumeration defense exercised by
/// `loginWithUnknownUserStillRunsBcryptVerify`) still runs at the production
/// cost.
func testPasswordHash(_ password: String) throws -> String {
    try Bcrypt.hash(password, cost: 4)
}

/// Creates `username` in the database (if not already present) with `role`,
/// then performs the full two-step GET /login → POST /login flow so the CSRF
/// token is valid. Returns the authenticated session cookie.
@discardableResult
func loginUser(
    username: String,
    password: String,
    role: String,
    on app: Application
) async throws -> String {
    if try await APIUser.query(on: app.db).filter(\.$username == username).first() == nil {
        let hash = try testPasswordHash(password)
        let user = APIUser(username: username, passwordHash: hash, role: role)
        try await user.save(on: app.db)
    }

    // Step 1: GET /login to generate a session and CSRF token.
    let (token, sessionCookie) = try await csrfFields(for: "/login", on: app)

    // Step 2: POST /login with the CSRF token bound to that session.
    var authCookie = sessionCookie
    try await app.asyncTest(
        .POST, "/login",
        beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(
                ["username": username, "password": password, "_csrf": token],
                as: .urlEncodedForm
            )
        },
        afterResponse: { res in
            // Use the new cookie if the session was rotated, otherwise keep the old one.
            if let c = res.headers.first(name: .setCookie) { authCookie = c }
        })
    return authCookie
}

/// Explicit-roster promotion: an admin promotes an already-enrolled user to a
/// per-course instructor. Teaching authority is per-course now (#417 Slice G2):
/// login auto-enrolls a non-admin as a `.student` and there is NO auto-grant, so
/// suites whose `.auto` fixtures used to rely on "auto-enroll the instructor on
/// login" call this after `loginUser(role: "instructor")` to simulate the admin
/// promotion. Upgrades every `.student` enrollment the user holds to
/// `.instructor` (a fresh test instructor's only enrollments are the ones login
/// just auto-created); anything enrolled explicitly at another role is untouched.
func promoteToInstructor(_ username: String, on app: Application) async throws {
    guard let user = try await APIUser.query(on: app.db).filter(\.$username == username).first(),
        let userID = user.id
    else { return }
    for enrollment in try await APICourseEnrollment.query(on: app.db)
        .filter(\.$userID == userID).all() where enrollment.role == .student
    {
        enrollment.role = .instructor
        try await enrollment.save(on: app.db)
    }
}
