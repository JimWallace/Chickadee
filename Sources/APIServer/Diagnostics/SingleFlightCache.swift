// Sources/APIServer/Diagnostics/SingleFlightCache.swift
//
// A single-flight, short-TTL cache in front of one expensive computation.
//
// The actor guarantees at most one in-flight computation at a time
// (concurrent callers await the same task) and serves a cached value for
// `ttl` seconds, so the expensive work runs at most once per TTL no matter
// how many pollers or pages ask for it.  Failures are never cached, and a
// failed task clears the in-flight slot so the next caller retries rather
// than awaiting a dead task.
//
// Two admin surfaces front their heaviest query with this: the metrics card
// series (`MetricsCardCache`) and the storage breakdown (`StorageUsageCache`).
// Each is a typealias plus a named accessor, so the call sites read as what
// they cache rather than as a generic `value(...)`.

import Foundation

actor SingleFlightCache<Value: Sendable> {
    private var cached: Value?
    private var cachedAt: Date?
    private var inFlight: Task<Value, Error>?
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 60) {
        self.ttl = ttl
    }

    /// Returns the cached value if it is younger than the TTL, otherwise runs
    /// `compute` — coalescing concurrent callers onto a single execution.
    func value(
        now: Date = Date(),
        compute: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
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
            inFlight = nil
            throw error
        }
    }
}
