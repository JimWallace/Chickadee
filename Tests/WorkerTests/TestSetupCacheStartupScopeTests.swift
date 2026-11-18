// Tests/WorkerTests/TestSetupCacheStartupScopeTests.swift
//
// Two `TestSetupCache` rules the 2026-11-10 mutation sweep (#2970) found
// unpinned:
//
// - Startup removes a legacy tombstone, which is a `.evicted-` name that
//   ends in `.tmp`, and nothing else. A `<key>.tmp` directory is a commit's
//   staging directory, and the next populate of its key cleans it
//   (`commit`). Startup must leave it alone: a second runner pointed at the
//   same work root may be committing it at that moment.
// - A failed eviction is logged as `test_setup_cache_evict_failed`. That log
//   line is the only trace an operator gets of an entry that could not be
//   evicted and still holds its disk.

import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(3))) struct TestSetupCacheStartupScopeTests {

    private static func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-cache-startup-\(UUID().uuidString)", isDirectory: true)
    }

    private static func makeStagingDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "echo test\n".write(to: dir.appendingPathComponent("test.sh"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test func startupRemovesOnlyLegacyTombstonesNotAnotherKeysStagingDirectory() throws {
        let fm = FileManager.default
        let root = Self.makeRoot()
        defer { try? fm.removeItem(at: root) }
        let legacyTombstone = root.appendingPathComponent(".evicted-old-key-uuid.tmp", isDirectory: true)
        let staging = root.appendingPathComponent("in-flight-key.tmp/prepared", isDirectory: true)
        for directory in [legacyTombstone.appendingPathComponent("prepared"), staging] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        _ = TestSetupCache(cacheRoot: root, maxEntries: 4)

        #expect(!fm.fileExists(atPath: legacyTombstone.path), "a legacy tombstone is removed at startup")
        #expect(fm.fileExists(atPath: staging.path), "a staging directory is not a tombstone")
    }

    /// The tombstone directory's path is taken by a plain file, so the rename
    /// into it fails and the eviction is skipped. The failure must be logged.
    @Test func aFailedEvictionIsLogged() async throws {
        let fm = FileManager.default
        let root = Self.makeRoot()
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = TestSetupCache(cacheRoot: root, maxEntries: 1)
        try Data("not a directory".utf8).write(to: root.appendingPathComponent(".evicted"))

        let capture = RunnerLogCapture()
        try await RunnerLogCapture.$current.withValue(capture) {
            for key in ["evict-fail-a", "evict-fail-b"] {
                let result = try await cache.acquire(testSetupID: key) { try Self.makeStagingDir() }
                try? fm.removeItem(at: result.directory)
            }
        }

        #expect(capture.events.contains("test_setup_cache_evict_failed"))
        #expect(
            fm.fileExists(atPath: root.appendingPathComponent("evict-fail-a").path),
            "an entry whose eviction failed stays where it was")
    }
}
