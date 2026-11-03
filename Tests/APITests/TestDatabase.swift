// Tests/APITests/TestDatabase.swift
//
// Gives each test application its own database: a schema from the Postgres
// pool, or a private Postgres schema for a suite that changes its schema.

import Fluent
import FluentPostgresDriver
import Foundation
import SQLKit
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

    // Borrow a pre-migrated schema from the process-wide pool.
    //
    // Of the 450.6 ms a Postgres test application costs, `autoMigrate` is
    // ~98 %, measured, and the cost is a product of migrations x applications
    // (~1,100 per-test Applications). `CREATE DATABASE ... TEMPLATE` was
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
    configureDatabase(app, settings: postgresSettings(settings, searchPath: [lease.schemaName]))

    // Registering is NOT the expensive part — running is; and it is
    // load-bearing. Six suites call `autoMigrate()` themselves and rely on it
    // being a clean no-op against a complete migration log, which an empty
    // registry would silently turn into "do nothing".
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
    let schemaName = newPrivateTestSchemaName()
    app.storage[TestPostgresSchemaKey.self] = schemaName
    configureDatabase(app, settings: postgresSettings(settings, searchPath: [schemaName]))
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

/// Gives the application a private, EMPTY schema of its own: for a suite that
/// builds a legacy table shape by hand before it migrates. `tearDownTestApp`
/// drops the schema.
func configureEmptyPostgresTestSchema(_ app: Application) async throws {
    let settings = try await withAsyncEnvLock { try testDatabaseSettingsFromEnvironment() }
    let schemaName = newPrivateTestSchemaName()
    app.storage[TestPostgresSchemaKey.self] = schemaName
    configureDatabase(app, settings: postgresSettings(settings, searchPath: [schemaName]))
    try await createPostgresTestSchema(app, schemaName: schemaName)
}

private func newPrivateTestSchemaName() -> String {
    "test_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12))"
}

/// Rebuilds Postgres settings with a different `search_path`, and optionally a
/// different pool size.
func postgresSettings(
    _ settings: DatabaseSettings,
    searchPath: [String]?,
    maxConnectionsPerEventLoop: Int? = nil
) -> DatabaseSettings {
    .postgres(
        host: settings.host,
        port: settings.port,
        database: settings.database,
        username: settings.username,
        password: settings.password,
        searchPath: searchPath,
        maxConnectionsPerEventLoop: maxConnectionsPerEventLoop
    )
}

struct TestPostgresSchemaKey: StorageKey {
    typealias Value = String
}

/// Quotes an identifier for safe interpolation into raw SQL.  Test schema
/// names are generated from a UUID so they shouldn't contain `"` themselves,
/// but escape anyway — defense in depth, no perf cost.
func quotedIdentifier(_ raw: String) -> String {
    "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

private func createPostgresTestSchema(_ app: Application, schemaName: String) async throws {
    guard let sql = app.db as? any SQLDatabase else { return }
    // CREATE SCHEMA is global and doesn't depend on search_path, so this
    // runs cleanly even though the freshly-configured connection has its
    // search_path pointing at the not-yet-existent schema.
    let quoted = quotedIdentifier(schemaName)
    try await sql.raw("CREATE SCHEMA \(unsafeRaw: quoted)").run()
}

func dropPostgresTestSchema(_ app: Application) async throws {
    let schemaNames =
        [app.storage[TestPostgresSchemaKey.self]].compactMap(\.self)
        + (app.storage[ExtraTestPostgresSchemasKey.self] ?? [])
    guard !schemaNames.isEmpty, let sql = app.db as? any SQLDatabase else { return }
    for schemaName in schemaNames {
        let quoted = quotedIdentifier(schemaName)
        try await sql.raw("DROP SCHEMA IF EXISTS \(unsafeRaw: quoted) CASCADE").run()
    }
}

/// Schemas a test made beside its own test database, which teardown drops too.
struct ExtraTestPostgresSchemasKey: StorageKey {
    typealias Value = [String]
}

/// Registers a second pool, `id`, on a new EMPTY schema: a stand-in for a
/// database that lacks every table, such as the least-privilege `.mcp` pool
/// that cannot see the student tables. `tearDownTestApp` drops the schema.
/// The app must already have its own test database.
func registerEmptyPostgresSchemaPool(on app: Application, as id: DatabaseID) async throws {
    let settings = try await withAsyncEnvLock { try testDatabaseSettingsFromEnvironment() }
    let schemaName = newPrivateTestSchemaName()
    guard let sql = app.db as? any SQLDatabase else {
        throw DatabaseConfigurationError.invalidSettings(
            "the app needs a SQL test database before a second pool")
    }
    try await sql.raw("CREATE SCHEMA \(unsafeRaw: quotedIdentifier(schemaName))").run()
    app.storage[ExtraTestPostgresSchemasKey.self] =
        (app.storage[ExtraTestPostgresSchemasKey.self] ?? []) + [schemaName]

    var configuration = SQLPostgresConfiguration(
        hostname: settings.host, port: settings.port, username: settings.username,
        password: settings.password, database: settings.database, tls: .disable)
    configuration.searchPath = [schemaName]
    app.databases.use(.postgres(configuration: configuration, maxConnectionsPerEventLoop: 1), as: id)
}

/// The test database: `DatabaseSettings.localTest` (localhost:5432, database
/// `chickadee_test`, user and password `postgres`), with each part overridden
/// by `TEST_DATABASE_HOST`, `TEST_DATABASE_PORT`, `TEST_DATABASE_NAME`,
/// `TEST_DATABASE_USER` or `TEST_DATABASE_PASSWORD` when set. CI sets all of
/// them to its postgres service.
func testDatabaseSettingsFromEnvironment() throws -> DatabaseSettings {
    func value(_ key: String) -> String? {
        guard let raw = EnvironmentSource.get(key)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }
        return raw
    }
    let defaults = DatabaseSettings.localTest
    var port = defaults.port
    if let rawPort = value("TEST_DATABASE_PORT") {
        guard let parsed = Int(rawPort) else {
            throw DatabaseConfigurationError.invalidSettings("TEST_DATABASE_PORT must be an integer")
        }
        port = parsed
    }
    return .postgres(
        host: value("TEST_DATABASE_HOST") ?? defaults.host,
        port: port,
        database: value("TEST_DATABASE_NAME") ?? defaults.database,
        username: value("TEST_DATABASE_USER") ?? defaults.username,
        password: value("TEST_DATABASE_PASSWORD") ?? defaults.password
    )
}
