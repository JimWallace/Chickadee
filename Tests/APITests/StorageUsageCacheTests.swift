// Tests/APITests/StorageUsageCacheTests.swift
//
// Pins the storage-breakdown cache's contract (#1382 item 5): a TTL-fresh
// context is served without recomputing, expiry recomputes, concurrent
// callers coalesce onto one computation, and failures are never cached.

import Foundation
import Testing

@testable import APIServer

@Suite struct StorageUsageCacheTests {

    private actor ComputeCounter {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    private static func makeContext(total: String) -> AdminStorageContext {
        AdminStorageContext(rows: [], totalFormatted: total, dbBackend: "sqlite", assignments: [])
    }

    @Test func servesCachedContextWithinTTLAndRecomputesAfter() async throws {
        let cache = StorageUsageCache(ttl: 60)
        let counter = ComputeCounter()
        let start = Date()

        let first = try await cache.context(now: start) {
            await counter.bump()
            return Self.makeContext(total: "1 B")
        }
        let second = try await cache.context(now: start.addingTimeInterval(30)) {
            await counter.bump()
            return Self.makeContext(total: "2 B")
        }
        #expect(first.totalFormatted == "1 B")
        #expect(second.totalFormatted == "1 B", "A TTL-fresh context is served from cache")
        #expect(await counter.count == 1)

        let third = try await cache.context(now: start.addingTimeInterval(61)) {
            await counter.bump()
            return Self.makeContext(total: "3 B")
        }
        #expect(third.totalFormatted == "3 B", "An expired context recomputes")
        #expect(await counter.count == 2)
    }

    @Test func concurrentCallersCoalesceOntoOneComputation() async throws {
        let cache = StorageUsageCache(ttl: 60)
        let counter = ComputeCounter()

        let results = await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await cache.context {
                        await counter.bump()
                        try await Task.sleep(nanoseconds: 50_000_000)
                        return Self.makeContext(total: "coalesced")
                    }.totalFormatted
                }
            }
            var collected: [String] = []
            while let value = try? await group.next() {
                collected.append(value)
            }
            return collected
        }

        #expect(results == ["coalesced", "coalesced", "coalesced", "coalesced"])
        #expect(await counter.count == 1, "Concurrent callers share one in-flight computation")
    }

    @Test func failuresAreNotCached() async throws {
        struct ComputeFailed: Error {}
        let cache = StorageUsageCache(ttl: 60)
        let counter = ComputeCounter()

        await #expect(throws: ComputeFailed.self) {
            try await cache.context {
                await counter.bump()
                throw ComputeFailed()
            }
        }
        let recovered = try await cache.context {
            await counter.bump()
            return Self.makeContext(total: "ok")
        }
        #expect(recovered.totalFormatted == "ok", "The next caller retries after a failure")
        #expect(await counter.count == 2)
    }
}
