// Sources/APIServer/Diagnostics/MetricsCardCache.swift
//
// Single-flight, short-TTL cache in front of `metricsCardSeries`.
//
// The card series scans up to 30 days of `RunnerSnapshot` /
// `JobExecutionMetric` rows — far heavier than the 24h `/admin/metrics`
// snapshot.  The admin dashboard polls it every 60s, and the instructor
// dashboard / retest traffic hit the database concurrently.  Without this
// cache, each poll ran the full scan on its own connection; overlapping
// requests stacked those long-held connections and exhausted the Fluent
// pool (observed as `ConnectionPoolTimeoutError` + 500s on unrelated pages).
//
// This actor guarantees at most one in-flight computation at a time
// (concurrent callers await the same task) and serves a cached result for
// `ttl` seconds, so the expensive query runs at most once per TTL no matter
// how many pollers or pages ask for it.

import Foundation
import Vapor

actor MetricsCardCache {
    private var cached: MetricsCardSeriesResponse?
    private var cachedAt: Date?
    private var inFlight: Task<MetricsCardSeriesResponse, Error>?
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 60) {
        self.ttl = ttl
    }

    /// Returns a cached series if it is younger than the TTL, otherwise runs
    /// `compute` — coalescing concurrent callers onto a single execution so
    /// the heavy scan never stacks on the connection pool.
    func series(
        now: Date = Date(),
        compute: @escaping @Sendable () async throws -> MetricsCardSeriesResponse
    ) async throws -> MetricsCardSeriesResponse {
        if let cached, let cachedAt, now.timeIntervalSince(cachedAt) < ttl {
            return cached
        }
        if let inFlight {
            return try await inFlight.value
        }

        let task = Task { try await compute() }
        inFlight = task
        do {
            let result = try await task.value
            cached = result
            cachedAt = now
            inFlight = nil
            return result
        } catch {
            // Don't cache failures, and clear the in-flight slot so the next
            // caller retries rather than awaiting a dead task.
            inFlight = nil
            throw error
        }
    }
}

struct MetricsCardCacheKey: StorageKey {
    typealias Value = MetricsCardCache
}

extension Application {
    /// Process-wide cache fronting the admin card sparkline series.  Lazily
    /// created on first access (mirrors `workerActivityStore`); a transient
    /// boot-time race just recomputes once.
    var metricsCardCache: MetricsCardCache {
        get {
            if let existing = storage[MetricsCardCacheKey.self] {
                return existing
            }
            let created = MetricsCardCache()
            storage[MetricsCardCacheKey.self] = created
            return created
        }
        set { storage[MetricsCardCacheKey.self] = newValue }
    }
}
