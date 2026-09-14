// Sources/APIServer/Diagnostics/StorageUsageCache.swift
//
// Single-flight, short-TTL cache in front of the admin storage breakdown
// (#1382 item 5).
//
// Building the breakdown walks every persistent-volume sink — the flat
// submissions directory (one stat per submission the deployment has ever
// kept), the test-setups tree, the results dir, and the whole static asset
// tree (~400 MB of vendored editor assets) — plus a full (id → setup)
// projection of the submissions table for byte attribution. That is exactly
// the work that grows as disk fills, on the one page whose purpose is "are
// we running out of disk", and it is reachable from the read-only admin MCP
// (`get_storage_usage`), which an agent may poll.
//
// The coalescing is `SingleFlightCache`, shared with `MetricsCardCache`: at
// most one computation in flight (concurrent callers await the same task)
// and a cached context served for `ttl` seconds, so the walks run at most
// once per TTL no matter how many pollers ask. A ≤60s-stale answer is fine
// for a disk-pressure panel; the numbers move on upload timescales, not
// seconds.

import Foundation
import Vapor

typealias StorageUsageCache = SingleFlightCache<AdminStorageContext>

extension SingleFlightCache where Value == AdminStorageContext {
    /// Returns a cached context if it is younger than the TTL, otherwise runs
    /// `compute` — coalescing concurrent callers onto a single execution so
    /// the directory walks never stack.
    func context(
        now: Date = Date(),
        compute: @escaping @Sendable () async throws -> AdminStorageContext
    ) async throws -> AdminStorageContext {
        try await value(now: now, compute: compute)
    }
}

private struct StorageUsageCacheKey: StorageKey {
    typealias Value = StorageUsageCache
}

extension Application {
    /// Process-wide cache fronting the admin storage breakdown (the
    /// `/admin/storage` page and the `get_storage_usage` MCP tool share it).
    var storageUsageCache: StorageUsageCache {
        get {
            lazyStored(StorageUsageCacheKey.self) { StorageUsageCache() }
        }
        set { storage[StorageUsageCacheKey.self] = newValue }
    }
}
