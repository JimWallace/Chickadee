// Tests/WorkerTests/TestSetupCacheTests.swift

import XCTest
@testable import chickadee_runner
import Foundation

final class TestSetupCacheTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a temporary cache root and returns a TestSetupCache backed by it.
    private func makeCache(maxEntries: Int = 16) -> (TestSetupCache, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-cache-test-\(UUID().uuidString)", isDirectory: true)
        let cache = TestSetupCache(cacheRoot: root, maxEntries: maxEntries)
        return (cache, root)
    }

    /// Creates a temporary directory with a sentinel file inside it, simulating
    /// a freshly unzipped test setup.
    private func makeStaging(name: String = "test_script.sh") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sentinel = dir.appendingPathComponent(name)
        try name.write(to: sentinel, atomically: true, encoding: .utf8)
        return dir
    }

    // MARK: - Cache miss populates once

    func testCacheMissPopulatesDirectory() async throws {
        let (cache, _) = makeCache()
        var populateCalled = 0

        let result = try await cache.acquire(testSetupID: "setup-1") {
            populateCalled += 1
            return try self.makeStaging()
        }
        defer { try? FileManager.default.removeItem(at: result) }

        XCTAssertEqual(populateCalled, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.appendingPathComponent("test_script.sh").path))
    }

    // MARK: - Repeated acquire hits cache (populate called only once)

    func testRepeatedAcquireHitsCache() async throws {
        let (cache, _) = makeCache()
        var populateCalled = 0

        let first = try await cache.acquire(testSetupID: "setup-2") {
            populateCalled += 1
            return try self.makeStaging()
        }
        defer { try? FileManager.default.removeItem(at: first) }

        let second = try await cache.acquire(testSetupID: "setup-2") {
            populateCalled += 1   // must NOT be called on a hit
            return try self.makeStaging()
        }
        defer { try? FileManager.default.removeItem(at: second) }

        XCTAssertEqual(populateCalled, 1, "populate must be called exactly once; second call should be a cache hit")
    }

    // MARK: - Jobs receive isolated copies

    func testJobsReceiveIsolatedCopies() async throws {
        let (cache, _) = makeCache()

        let first = try await cache.acquire(testSetupID: "setup-3") {
            return try self.makeStaging(name: "sentinel.sh")
        }
        defer { try? FileManager.default.removeItem(at: first) }

        let second = try await cache.acquire(testSetupID: "setup-3") {
            XCTFail("populate must not be called on cache hit")
            return try self.makeStaging()
        }
        defer { try? FileManager.default.removeItem(at: second) }

        // Both copies exist and contain the sentinel file.
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent("sentinel.sh").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.appendingPathComponent("sentinel.sh").path))

        // The two scratch directories are distinct paths.
        XCTAssertNotEqual(first.path, second.path)

        // Mutating one copy does not affect the other or the cache entry.
        let extraFile = first.appendingPathComponent("mutation.txt")
        try "mutated".write(to: extraFile, atomically: true, encoding: .utf8)

        XCTAssertFalse(FileManager.default.fileExists(atPath: second.appendingPathComponent("mutation.txt").path))
    }

    // MARK: - Concurrent requests populate only once

    func testConcurrentRequestsPopulateOnce() async throws {
        let (cache, _) = makeCache()
        let populateCount = LockIsolated(0)

        // Launch several concurrent acquires for the same testSetupID.
        let results = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await cache.acquire(testSetupID: "setup-concurrent") {
                        populateCount.increment()
                        // Small delay to allow other tasks to pile up.
                        try await Task.sleep(for: .milliseconds(20))
                        return try self.makeStaging()
                    }
                }
            }
            var urls: [URL] = []
            for try await url in group { urls.append(url) }
            return urls
        }

        defer {
            for url in results { try? FileManager.default.removeItem(at: url) }
        }

        XCTAssertEqual(populateCount.value, 1, "populate must be called exactly once across concurrent acquires")
        XCTAssertEqual(results.count, 8)

        // All returned paths are distinct scratch copies.
        let unique = Set(results.map(\.path))
        XCTAssertEqual(unique.count, 8, "each job must receive its own scratch copy")
    }

    // MARK: - Failed population does not persist

    func testFailedPopulationLeavesNoEntry() async throws {
        let (cache, root) = makeCache()

        struct PopulateError: Error {}

        do {
            _ = try await cache.acquire(testSetupID: "setup-fail") {
                throw PopulateError()
            }
            XCTFail("Expected error to propagate")
        } catch is PopulateError {
            // Expected.
        }

        // No entry directory should remain.
        let entryRoot = root.appendingPathComponent("setup-fail")
        let tmpRoot   = root.appendingPathComponent("setup-fail.tmp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: entryRoot.path), "partial entry must be cleaned up")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpRoot.path),   "staging tmp must be cleaned up")

        // A subsequent acquire should retry (populate called again).
        var retryCount = 0
        let result = try await cache.acquire(testSetupID: "setup-fail") {
            retryCount += 1
            return try self.makeStaging()
        }
        defer { try? FileManager.default.removeItem(at: result) }
        XCTAssertEqual(retryCount, 1, "after a failed population the next acquire must re-populate")
    }

    // MARK: - LRU eviction

    func testLRUEvictionBoundsCache() async throws {
        let maxEntries = 4
        let (cache, root) = makeCache(maxEntries: maxEntries)

        // Populate exactly maxEntries + 1 distinct setups.
        for i in 0..<(maxEntries + 1) {
            let result = try await cache.acquire(testSetupID: "setup-evict-\(i)") {
                try self.makeStaging(name: "script-\(i).sh")
            }
            try? FileManager.default.removeItem(at: result)
        }

        // Count how many entry directories exist under cacheRoot.
        var entryCount = 0
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) {
            for case let url as URL in enumerator {
                let vals = try url.resourceValues(forKeys: [.isDirectoryKey])
                if vals.isDirectory == true { entryCount += 1 }
            }
        }

        XCTAssertEqual(entryCount, maxEntries,
            "cache must contain exactly maxEntries=\(maxEntries) directories after \(maxEntries + 1) inserts")
    }

    func testLRUEvictsLeastRecentlyUsed() async throws {
        let (cache, root) = makeCache(maxEntries: 2)

        // Insert A then B (cache is now full: [A, B], A is LRU).
        let a1 = try await cache.acquire(testSetupID: "A") { try self.makeStaging(name: "a.sh") }
        defer { try? FileManager.default.removeItem(at: a1) }

        let b1 = try await cache.acquire(testSetupID: "B") { try self.makeStaging(name: "b.sh") }
        defer { try? FileManager.default.removeItem(at: b1) }

        // Access A again to make it MRU (LRU order becomes [B, A]).
        let a2 = try await cache.acquire(testSetupID: "A") {
            XCTFail("A should still be cached"); return try self.makeStaging()
        }
        defer { try? FileManager.default.removeItem(at: a2) }

        // Insert C — cache is full, so B (LRU) must be evicted.
        let c1 = try await cache.acquire(testSetupID: "C") { try self.makeStaging(name: "c.sh") }
        defer { try? FileManager.default.removeItem(at: c1) }

        let aEntry = root.appendingPathComponent("A")
        let bEntry = root.appendingPathComponent("B")
        let cEntry = root.appendingPathComponent("C")

        XCTAssertTrue (FileManager.default.fileExists(atPath: aEntry.path), "A must remain (was MRU when C inserted)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bEntry.path), "B must be evicted (was LRU when C inserted)")
        XCTAssertTrue (FileManager.default.fileExists(atPath: cEntry.path), "C must be present")
    }
}

// MARK: - Concurrency helper

/// Minimal thread-safe counter for use in async test closures.
private final class LockIsolated: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int

    init(_ initial: Int = 0) { _value = initial }

    var value: Int {
        lock.withLock { _value }
    }

    func increment() {
        lock.withLock { _value += 1 }
    }
}
