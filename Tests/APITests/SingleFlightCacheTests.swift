// Tests/APITests/SingleFlightCacheTests.swift
//
// The generic actor behind `MetricsCardCache` and `StorageUsageCache`. The
// two specialised suites pin their accessors; this one pins the shared
// contract on a plain value type.

import Foundation
import Testing

@testable import APIServer

@Suite struct SingleFlightCacheTests {
    private actor Counter {
        var calls = 0
        func increment() -> Int {
            calls += 1
            return calls
        }
    }

    @Test func servesTheCachedValueInsideTheTTL() async throws {
        let cache = SingleFlightCache<Int>(ttl: 60)
        let counter = Counter()
        let base = Date()
        let first = try await cache.value(now: base) { await counter.increment() }
        let second = try await cache.value(now: base.addingTimeInterval(30)) { await counter.increment() }
        #expect(first == 1)
        #expect(second == 1)
    }

    @Test func recomputesOnceTheTTLHasPassed() async throws {
        let cache = SingleFlightCache<Int>(ttl: 60)
        let counter = Counter()
        let base = Date()
        _ = try await cache.value(now: base) { await counter.increment() }
        let later = try await cache.value(now: base.addingTimeInterval(61)) { await counter.increment() }
        #expect(later == 2)
    }

    @Test func doesNotCacheAFailure() async throws {
        struct Boom: Error {}
        let cache = SingleFlightCache<Int>(ttl: 60)
        let counter = Counter()
        await #expect(throws: Boom.self) {
            try await cache.value { () async throws -> Int in throw Boom() }
        }
        let recovered = try await cache.value { await counter.increment() }
        #expect(recovered == 1)
    }

    @Test func concurrentCallersShareOneComputation() async throws {
        let cache = SingleFlightCache<Int>(ttl: 60)
        let counter = Counter()
        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await cache.value {
                        try await Task.sleep(for: .milliseconds(20))
                        return await counter.increment()
                    }
                }
            }
            var collected: [Int] = []
            for try await value in group { collected.append(value) }
            return collected
        }
        #expect(Set(results) == [1])
    }
}
