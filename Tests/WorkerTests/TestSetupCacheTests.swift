// Tests/WorkerTests/TestSetupCacheTests.swift

import XCTest
@testable import chickadee_runner
import Foundation

// MARK: - Free helpers (not methods — must not capture `self` in @Sendable closures)

/// Creates a temporary directory with a sentinel file, simulating a freshly
/// unzipped test setup.  Free function so it is callable from @Sendable closures.
private func makeTestStagingDir(name: String = "test_script.sh") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try name.write(
        to: dir.appendingPathComponent(name),
        atomically: true,
        encoding: .utf8
    )
    return dir
}

// MARK: - TestSetupCacheTests

final class TestSetupCacheTests: XCTestCase {

    // MARK: - Helpers

    private func makeCache(maxEntries: Int = 16) -> (TestSetupCache, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-cache-test-\(UUID().uuidString)", isDirectory: true)
        return (TestSetupCache(cacheRoot: root, maxEntries: maxEntries), root)
    }

    // MARK: - Cache miss populates once

    func testCacheMissPopulatesDirectory() async throws {
        let (cache, _) = makeCache()
        let populateCalled = Counter()

        let result = try await cache.acquire(testSetupID: "setup-1") {
            populateCalled.increment()
            return try makeTestStagingDir()
        }
        defer { try? FileManager.default.removeItem(at: result) }

        XCTAssertEqual(populateCalled.value, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: result.appendingPathComponent("test_script.sh").path
            )
        )
    }

    // MARK: - Repeated acquire hits cache (populate called only once)

    func testRepeatedAcquireHitsCache() async throws {
        let (cache, _) = makeCache()
        let populateCalled = Counter()

        let first = try await cache.acquire(testSetupID: "setup-2") {
            populateCalled.increment()
            return try makeTestStagingDir()
        }
        defer { try? FileManager.default.removeItem(at: first) }

        let second = try await cache.acquire(testSetupID: "setup-2") {
            populateCalled.increment()   // must NOT be called on a hit
            return try makeTestStagingDir()
        }
        defer { try? FileManager.default.removeItem(at: second) }

        XCTAssertEqual(
            populateCalled.value, 1,
            "populate must be called exactly once; second call should be a cache hit"
        )
    }

    // MARK: - Jobs receive isolated copies

    func testJobsReceiveIsolatedCopies() async throws {
        let (cache, _) = makeCache()

        let first = try await cache.acquire(testSetupID: "setup-3") {
            return try makeTestStagingDir(name: "sentinel.sh")
        }
        defer { try? FileManager.default.removeItem(at: first) }

        let second = try await cache.acquire(testSetupID: "setup-3") {
            XCTFail("populate must not be called on cache hit")
            return try makeTestStagingDir()
        }
        defer { try? FileManager.default.removeItem(at: second) }

        // Both copies contain the sentinel file.
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: first.appendingPathComponent("sentinel.sh").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: second.appendingPathComponent("sentinel.sh").path
            )
        )

        // The two scratch directories are distinct paths.
        XCTAssertNotEqual(first.path, second.path)

        // Mutating one copy does not affect the other.
        try "mutated".write(
            to: first.appendingPathComponent("mutation.txt"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: second.appendingPathComponent("mutation.txt").path
            )
        )
    }

    // MARK: - Concurrent requests populate only once

    func testConcurrentRequestsPopulateOnce() async throws {
        let (cache, _) = makeCache()
        let populateCount = Counter()

        let results = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await cache.acquire(testSetupID: "setup-concurrent") {
                        populateCount.increment()
                        // Small delay to let other tasks pile up.
                        try await Task.sleep(for: .milliseconds(20))
                        return try makeTestStagingDir()
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

        XCTAssertEqual(
            populateCount.value, 1,
            "populate must be called exactly once across concurrent acquires"
        )
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

        // No entry directory or staging tmp should remain.
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("setup-fail").path
            ),
            "partial entry must be cleaned up"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("setup-fail.tmp").path
            ),
            "staging tmp must be cleaned up"
        )

        // A subsequent acquire must retry populate.
        let retryCount = Counter()
        let result = try await cache.acquire(testSetupID: "setup-fail") {
            retryCount.increment()
            return try makeTestStagingDir()
        }
        defer { try? FileManager.default.removeItem(at: result) }
        XCTAssertEqual(retryCount.value, 1, "after a failed population the next acquire must re-populate")
    }

    // MARK: - LRU eviction bounds the cache

    func testLRUEvictionBoundsCache() async throws {
        let maxEntries = 4
        let (cache, root) = makeCache(maxEntries: maxEntries)

        for i in 0..<(maxEntries + 1) {
            let result = try await cache.acquire(testSetupID: "setup-evict-\(i)") {
                try makeTestStagingDir(name: "script-\(i).sh")
            }
            try? FileManager.default.removeItem(at: result)
        }

        // Count immediate subdirectory entries under cacheRoot.
        var entryCount = 0
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for url in contents {
                let vals = try url.resourceValues(forKeys: [.isDirectoryKey])
                if vals.isDirectory == true { entryCount += 1 }
            }
        }

        XCTAssertEqual(
            entryCount, maxEntries,
            "cache must hold exactly \(maxEntries) directories after \(maxEntries + 1) inserts"
        )
    }

    // MARK: - LRU evicts least-recently-used entry

    func testLRUEvictsLeastRecentlyUsed() async throws {
        let (cache, root) = makeCache(maxEntries: 2)

        // Insert A then B (cache full; A is LRU).
        let a1 = try await cache.acquire(testSetupID: "A") { try makeTestStagingDir(name: "a.sh") }
        defer { try? FileManager.default.removeItem(at: a1) }

        let b1 = try await cache.acquire(testSetupID: "B") { try makeTestStagingDir(name: "b.sh") }
        defer { try? FileManager.default.removeItem(at: b1) }

        // Re-access A so LRU order becomes [B, A] (B is now LRU).
        let a2 = try await cache.acquire(testSetupID: "A") {
            XCTFail("A should still be cached"); return try makeTestStagingDir()
        }
        defer { try? FileManager.default.removeItem(at: a2) }

        // Insert C — B (LRU) must be evicted.
        let c1 = try await cache.acquire(testSetupID: "C") { try makeTestStagingDir(name: "c.sh") }
        defer { try? FileManager.default.removeItem(at: c1) }

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("A").path
            ),
            "A must remain (was MRU when C inserted)"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("B").path
            ),
            "B must be evicted (was LRU when C inserted)"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("C").path
            ),
            "C must be present"
        )
    }
}

// MARK: - Thread-safe counter

/// Thread-safe integer counter for use inside @Sendable closures in tests.
///
/// `@unchecked Sendable`: all mutable state is protected by `NSLock`; the
/// checker cannot verify this statically, but the invariant is upheld manually.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}
