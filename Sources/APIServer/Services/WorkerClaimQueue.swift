// APIServer/Services/WorkerClaimQueue.swift
//
// Application-level claim serializer for runner job claims (split out of
// WorkerJobRoutes.swift in the 0.5 cleanup). One queue per Application,
// seeded eagerly in bootstrapAppDirectories.

import Vapor

/// Ensures at most one worker-job claim operation executes at a time —
/// **SQLite only** (#1172 moved Postgres to `FOR UPDATE SKIP LOCKED`, which
/// needs no in-process serialization). Claim *correctness* comes from the
/// compare-and-set UPDATE in `atomicallyClaimSubmission` (its
/// `status == pending` guard is atomic); this queue exists so concurrent
/// in-process polls don't thrash SQLite's write lock and burn busy-retries.
/// The section it guards is one UPDATE + one SELECT (2026-07 audit —
/// evaluation moved outside).
struct WorkerClaimQueue: Sendable {
    private let gate = AsyncCountingSemaphore(width: 1)

    func run<T>(_ work: () async throws -> T) async throws -> T {
        try await gate.withPermit(work)
    }
}

struct WorkerClaimQueueKey: StorageKey {
    typealias Value = WorkerClaimQueue
}

extension Application {
    var workerClaimQueue: WorkerClaimQueue {
        if let q = storage[WorkerClaimQueueKey.self] { return q }
        let q = WorkerClaimQueue()
        storage[WorkerClaimQueueKey.self] = q
        return q
    }
}
