// Tests/APITests/TestAppTempDirectoryTests.swift
//
// The test harness must not leak its own scratch directories.
//
// It did, for a long time and invisibly: `makeTestApp` built its per-app temp
// path with a trailing slash inside `appendingPathComponent`, and `URL.path`
// strips that, so the five directories it then created by string concatenation
// were SIBLINGS of the intended parent rather than children. Nothing created
// the parent, so `tearDownTestApp`'s `removeItem` deleted a path that never
// existed — and its `try?` swallowed the error, so cleanup reported success
// while removing nothing. A full suite run leaked ~1.4 GB across ~6,900
// entries; a working session filled a 252 GB disk. See issue #1298.
//
// The two smaller leaks the same issue kept open are pinned here too:
//   - suites route teardown through `withApp`, which used to only shut the
//     app down — the directory tree survived (~45 MB / ~1,400 entries);
//   - sqlite-kit backs every `.memory` database with a real file in the
//     system temp directory and never deletes it (~973 MB / ~1,566 entries).
//
// These assert the OUTCOME (nothing survives) rather than that cleanup ran,
// because "cleanup ran" is exactly what was true the whole time it was broken.

import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct TestAppTempDirectoryTests {

    private var temporaryDirectory: String {
        FileManager.default.temporaryDirectory.path
    }

    /// Entries in the system temp directory whose name starts with `prefix`.
    /// Deliberately a prefix scan of the whole directory rather than a look
    /// inside the app's own path: the bug produced siblings, which an inside
    /// look cannot see by construction.
    private func entries(matching prefix: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: temporaryDirectory)) ?? [])
            .filter { $0.hasPrefix(prefix) }
    }

    @Test func theAppsDirectoriesAreChildrenOfItsTempDirectory() async throws {
        let prefix = "chickadee-tmptest-\(UUID().uuidString)"
        let app = try await makeTestApp(prefix: prefix)
        // withApp, not `defer { Task { tearDownTestApp } }`: a fire-and-forget
        // task races test-runner exit and sometimes never ran, leaking the very
        // directory this suite is about.
        try await withApp(app) { app in
            let root = try #require(app.testDataDirectory)
            var isDirectory: ObjCBool = false
            #expect(
                FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory),
                "the recorded test data directory must actually exist — it is what teardown removes")
            #expect(isDirectory.boolValue)

            // Each configured directory must live INSIDE the recorded root. This is
            // the assertion the sibling bug fails: `.../<uuid>results/` does not
            // have `.../<uuid>/` as a prefix.
            for directory in [
                app.resultsDirectory, app.testSetupsDirectory, app.submissionsDirectory,
                app.dataExportsDirectory, app.contentFilesDirectory,
            ] {
                #expect(
                    directory.hasPrefix(root),
                    "\(directory) is not inside \(root) — teardown will not remove it")
            }
            // The two dotfiles are built by the same concatenation and leaked the
            // same way.
            #expect(app.workerSecretFilePath.hasPrefix(root))
            #expect(app.localRunnerAutoStartFilePath.hasPrefix(root))
        }
    }

    @Test func tearDownLeavesNothingBehind() async throws {
        let prefix = "chickadee-tmptest-\(UUID().uuidString)"
        #expect(entries(matching: prefix).isEmpty, "prefix must be unique to this test")

        let app = try await makeTestApp(prefix: prefix)
        #expect(
            !entries(matching: prefix).isEmpty,
            "the app should have created something to clean up")

        try await app.tearDownTestApp()

        #expect(
            entries(matching: prefix).isEmpty,
            """
            \(entries(matching: prefix)) survived teardown. Anything matching the app's prefix \
            must be removed — the leak this guards against produced SIBLINGS of the directory \
            teardown deletes, so it cleaned up successfully and left everything behind.
            """)
    }

    /// `withApp` is how nearly every suite ends its app, so it must be a FULL
    /// teardown. It used to only call `asyncShutdown()`: every class suite
    /// following the documented `makeTestApp` + `withApp` pattern leaked its
    /// directory tree, ~1,400 of them per run.
    @Test func withAppLeavesNothingBehind() async throws {
        let prefix = "chickadee-tmptest-\(UUID().uuidString)"
        let app = try await makeTestApp(prefix: prefix)

        // In the sqlite lane the app's "in-memory" database is secretly a real
        // file; require the discovery so a silent break (e.g. sqlite-kit
        // renaming its temp files) fails here instead of quietly re-leaking.
        let backend = try await withAsyncEnvLock {
            try testDatabaseSettingsFromEnvironment().backend
        }
        var sqliteFiles: [String] = []
        if backend == .sqlite {
            sqliteFiles = await app.sqliteFakeMemoryDatabaseFiles()
            try #require(
                !sqliteFiles.isEmpty,
                """
                could not locate the file backing the fake in-memory database. If sqlite-kit \
                changed how `.memory` storage is materialized, update \
                `sqliteFakeMemoryDatabaseFiles()` — until then every test app leaks that file \
                again.
                """)
            for file in sqliteFiles {
                #expect(FileManager.default.fileExists(atPath: file))
            }
        }

        try await withApp(app) { _ in }

        #expect(
            entries(matching: prefix).isEmpty,
            "\(entries(matching: prefix)) survived withApp — it must tear down, not just shut down")
        for file in sqliteFiles {
            #expect(
                !FileManager.default.fileExists(atPath: file),
                "the sqlite-kit fake-memory database file survived withApp: \(file)")
        }
    }

    /// Apps built without `makeTestApp` (bare `Application.make` plus a direct
    /// `configureDatabase(.sqliteInMemory())`) materialize the same hidden
    /// file; `tearDownTestApp` must find and remove it for them too. Runs in
    /// both database lanes — the settings here are explicit, not env-derived.
    @Test func tearDownRemovesTheFakeMemoryDatabaseFileOfABareApp() async throws {
        let app = try await makeTestingApplication { app in
            try configureDatabase(app, settings: .sqliteInMemory())
        }

        // Discovery opens the pool's first connection, which is also what
        // materializes the file — asserting existence right after is
        // deterministic.
        let sqliteFiles = await app.sqliteFakeMemoryDatabaseFiles()
        try #require(
            !sqliteFiles.isEmpty,
            "could not locate the file backing the fake in-memory database (see withAppLeavesNothingBehind)"
        )
        for file in sqliteFiles {
            #expect(FileManager.default.fileExists(atPath: file))
        }

        try await app.tearDownTestApp()

        for file in sqliteFiles {
            #expect(
                !FileManager.default.fileExists(atPath: file),
                "the sqlite-kit fake-memory database file survived tearDownTestApp: \(file)")
        }
    }
}
