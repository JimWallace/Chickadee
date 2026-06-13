import Foundation
import Testing

@testable import APIServer

@Suite struct MetricsCardCacheTests {
    private func emptyResponse(now: Date = Date()) -> MetricsCardSeriesResponse {
        MetricsCardSeriesResponse(generatedAt: now, windows: [])
    }

    /// A second call inside the TTL must return the cached value without
    /// running the (expensive) compute closure again.
    @Test func cachesWithinTTL() async throws {
        let cache = MetricsCardCache(ttl: 60)
        let counter = Counter()
        let base = Date(timeIntervalSince1970: 1_000)

        _ = try await cache.series(now: base) {
            await counter.increment()
            return self.emptyResponse()
        }
        _ = try await cache.series(now: base.addingTimeInterval(30)) {
            await counter.increment()
            return self.emptyResponse()
        }

        #expect(await counter.value == 1)
    }

    /// Past the TTL the cache recomputes.
    @Test func recomputesAfterTTL() async throws {
        let cache = MetricsCardCache(ttl: 60)
        let counter = Counter()
        let base = Date(timeIntervalSince1970: 1_000)

        _ = try await cache.series(now: base) {
            await counter.increment()
            return self.emptyResponse()
        }
        _ = try await cache.series(now: base.addingTimeInterval(61)) {
            await counter.increment()
            return self.emptyResponse()
        }

        #expect(await counter.value == 2)
    }

    /// Concurrent callers on a cold cache must coalesce onto one computation
    /// — this is what stops the heavy scan from stacking on the DB pool.
    @Test func concurrentCallersShareOneComputation() async throws {
        let cache = MetricsCardCache(ttl: 60)
        let counter = Counter()
        let base = Date(timeIntervalSince1970: 1_000)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    _ = try await cache.series(now: base) {
                        await counter.increment()
                        // Hold long enough that all callers pile up behind the
                        // single in-flight task.
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        return self.emptyResponse()
                    }
                }
            }
            try await group.waitForAll()
        }

        #expect(await counter.value == 1)
    }

    /// A failed computation is not cached: the next caller retries.
    @Test func doesNotCacheFailures() async throws {
        struct Boom: Error {}
        let cache = MetricsCardCache(ttl: 60)
        let counter = Counter()
        let base = Date(timeIntervalSince1970: 1_000)

        await #expect(throws: Boom.self) {
            _ = try await cache.series(now: base) {
                await counter.increment()
                throw Boom()
            }
        }
        _ = try await cache.series(now: base.addingTimeInterval(1)) {
            await counter.increment()
            return self.emptyResponse()
        }

        #expect(await counter.value == 2)
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}
