// Tests/APITests/TestApp.swift
//
// Builds the standard test application, runs a test body against it, and
// tears it down with every piece of temp state it made.

import CSRF
import ChickadeeTestSupport
import Foundation
import Leaf
import LeafKit
import SQLKit
import VaporTesting

@testable import APIServer

// MARK: - Async app lifecycle

/// Runs an async test body with a Vapor application and always tears it down:
/// shutdown plus removal of any temp state the harness created for it (the
/// `makeTestApp` directory tree, the file sqlite-kit secretly backs an
/// "in-memory" database with, the per-test Postgres schema). Safe for bare
/// apps too — each cleanup step is a no-op when there is nothing to clean.
///
/// It is also where APITests arms `WedgeWatchdog`. This is the target's one
/// universal test-body scope — 249 of its 539 files call it directly, about
/// two-thirds of the target's tests, and `withWebRoutesApp` /
/// `withAssignmentRoutesApp` funnel into it — so wrapping it means every test
/// that starts or finishes resets the stall clock, and the watchdog stays
/// armed exactly while test bodies are in flight. `.timeLimit`, which 77
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

        // The data-export drain, registered here for the same reason: a test
        // that requests an export and returns used to leave generation running
        // past `withApp`'s shutdown, and the first query after shutdown trapped
        // in Fluent's accessor (#1700). Production registers it in
        // `bootstrapAppServices`; `DataExportDrainWiringTests` pins that.
        app.lifecycle.use(DataExportDrainLifecycleHandler())

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
