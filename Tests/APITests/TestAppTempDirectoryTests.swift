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
        defer { Task { try? await app.tearDownTestApp() } }

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
}
