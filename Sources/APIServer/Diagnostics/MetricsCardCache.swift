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
// The coalescing itself is `SingleFlightCache`; this file names the
// specialisation and its accessor.

import Foundation
import Vapor

typealias MetricsCardCache = SingleFlightCache<MetricsCardSeriesResponse>

extension SingleFlightCache where Value == MetricsCardSeriesResponse {
    /// Returns a cached series if it is younger than the TTL, otherwise runs
    /// `compute` — coalescing concurrent callers onto a single execution so
    /// the heavy scan never stacks on the connection pool.
    func series(
        now: Date = Date(),
        compute: @escaping @Sendable () async throws -> MetricsCardSeriesResponse
    ) async throws -> MetricsCardSeriesResponse {
        try await value(now: now, compute: compute)
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
            lazyStored(MetricsCardCacheKey.self) { MetricsCardCache() }
        }
        set { storage[MetricsCardCacheKey.self] = newValue }
    }
}
