// Tests/APITests/MigratedSQLiteTemplate.swift
//
// A once-migrated SQLite database that each test application gets a copy of.

import Foundation
import Synchronization
import VaporTesting

@testable import APIServer

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
func configureFromMigratedTemplate(_ app: Application, logLevel: Logger.Level) async throws {
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
