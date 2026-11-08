// Tests/WorkerTests/TestSetupCacheTombstoneTests.swift
//
// An evicted entry is renamed into the hidden `.evicted/` directory under the
// cache root and deleted there, off the actor. The background delete must
// never remove a direct child of the cache root: on Linux,
// `contentsOfDirectory(at:includingPropertiesForKeys:options:)` throws when a
// child is deleted during the read, which made `lRUEvictionBoundsCache` count
// 0 entries in CI. Startup removes `.evicted/` and the tombstones that the
// runner before it left in the cache root itself.

import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(3))) struct TestSetupCacheTombstoneTests {

    private static func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-cache-tombstone-\(UUID().uuidString)", isDirectory: true)
    }

    private static func makeStagingDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "echo test\n".write(to: dir.appendingPathComponent("test.sh"), atomically: true, encoding: .utf8)
        return dir
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    @Test func startupRemovesTheTombstoneDirectoryAndLegacyTombstones() throws {
        let fm = FileManager.default
        let root = Self.makeRoot()
        defer { try? fm.removeItem(at: root) }
        let tombstone = root.appendingPathComponent(".evicted/old-key-1.tmp/prepared", isDirectory: true)
        let legacyTombstone = root.appendingPathComponent(".evicted-old-key-2-uuid.tmp", isDirectory: true)
        let liveEntry = root.appendingPathComponent("live-key/prepared", isDirectory: true)
        for directory in [tombstone, legacyTombstone.appendingPathComponent("prepared"), liveEntry] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        _ = TestSetupCache(cacheRoot: root, maxEntries: 4)

        #expect(!fm.fileExists(atPath: root.appendingPathComponent(".evicted").path))
        #expect(!fm.fileExists(atPath: legacyTombstone.path))
        #expect(fm.fileExists(atPath: liveEntry.path), "startup must keep a live entry")
    }

    /// After an eviction, the only new child of the cache root is the
    /// tombstone directory, and it outlives the background delete. Both hold
    /// as soon as `acquire` returns: the rename and the directory's creation
    /// run on the actor before it returns, and the delete removes only a
    /// child of `.evicted/`.
    @Test func evictionRenamesTheEntryIntoTheTombstoneDirectory() async throws {
        let fm = FileManager.default
        let root = Self.makeRoot()
        defer { try? fm.removeItem(at: root) }
        let cache = TestSetupCache(cacheRoot: root, maxEntries: 1)

        for key in ["tombstone-a", "tombstone-b"] {
            let result = try await cache.acquire(testSetupID: key) { try Self.makeStagingDir() }
            try? fm.removeItem(at: result.directory)
        }

        #expect(Self.isDirectory(root.appendingPathComponent(".evicted")))
        let children = try fm.contentsOfDirectory(atPath: root.path).sorted()
        #expect(children == [".evicted", "tombstone-b"], "no tombstone may sit in the cache root itself")
    }
}
