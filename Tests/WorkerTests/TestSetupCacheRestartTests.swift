// Tests/WorkerTests/TestSetupCacheRestartTests.swift
//
// A restarted runner rebuilds its LRU order from the entries already on disk,
// oldest modification first. `TestSetupCacheTests` covers eviction inside one
// process only, so the mutation sweep of 2026-09-22 (#1574) showed that
// reversing the restored order (`lhsDate < rhsDate` to `>`) went unseen: the
// first eviction after every restart would then drop the NEWEST entry and keep
// the stale one.

import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(3))) struct TestSetupCacheRestartTests {

    private static func stagingDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "echo".write(to: dir.appendingPathComponent("test.sh"), atomically: true, encoding: .utf8)
        return dir
    }

    /// The modification dates are set against the creation order, so the
    /// test cannot pass by accident of which entry was written first.
    @Test func afterARestartTheOldestEntryOnDiskIsEvictedFirst() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-cache-restart-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let before = TestSetupCache(cacheRoot: root, maxEntries: 2)
        for key in ["A", "B"] {
            let result = try await before.acquire(testSetupID: key) { try Self.stagingDir() }
            try? FileManager.default.removeItem(at: result.directory)
        }
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
            ofItemAtPath: root.appendingPathComponent("A").path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_500_000_000)],
            ofItemAtPath: root.appendingPathComponent("B").path)

        let after = TestSetupCache(cacheRoot: root, maxEntries: 2)
        let result = try await after.acquire(testSetupID: "C") { try Self.stagingDir() }
        try? FileManager.default.removeItem(at: result.directory)

        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("A").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("B").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("C").path))
    }
}
