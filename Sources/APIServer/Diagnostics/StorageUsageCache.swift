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
// This actor mirrors `MetricsCardCache`: at most one computation in flight
// (concurrent callers await the same task) and a cached context served for
// `ttl` seconds, so the walks run at most once per TTL no matter how many
// pollers ask. A ≤60s-stale answer is fine for a disk-pressure panel; the
// numbers move on upload timescales, not seconds.

import Foundation
import Vapor

actor StorageUsageCache {
    private var cached: AdminStorageContext?
    private var cachedAt: Date?
    private var inFlight: Task<AdminStorageContext, Error>?
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 60) {
        self.ttl = ttl
    }

    /// Returns a cached context if it is younger than the TTL, otherwise runs
    /// `compute` — coalescing concurrent callers onto a single execution so
    /// the directory walks never stack.
    func context(
        now: Date = Date(),
        compute: @escaping @Sendable () async throws -> AdminStorageContext
    ) async throws -> AdminStorageContext {
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

private struct StorageUsageCacheKey: StorageKey {
    typealias Value = StorageUsageCache
}

extension Application {
    /// Process-wide cache fronting the admin storage breakdown (the
    /// `/admin/storage` page and the `get_storage_usage` MCP tool share it).
    var storageUsageCache: StorageUsageCache {
        get {
            if let existing = storage[StorageUsageCacheKey.self] {
                return existing
            }
            let created = StorageUsageCache()
            storage[StorageUsageCacheKey.self] = created
            return created
        }
        set { storage[StorageUsageCacheKey.self] = newValue }
    }
}
