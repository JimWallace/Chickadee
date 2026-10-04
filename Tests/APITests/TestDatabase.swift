// Tests/APITests/TestDatabase.swift
//
// Gives each test application its own database: a copy of the migrated
// SQLite template, a schema from the Postgres pool, or a private Postgres
// schema for a suite that changes its schema.

import Fluent
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
    // in `configureFromMigratedTemplate`. Six suites call `autoMigrate()` themselves and rely on it being a
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

/// Quotes an identifier for safe interpolation into raw SQL.  Test schema
/// names are generated from a UUID so they shouldn't contain `"` themselves,
/// but escape anyway — defense in depth, no perf cost.
func quotedIdentifier(_ raw: String) -> String {
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
