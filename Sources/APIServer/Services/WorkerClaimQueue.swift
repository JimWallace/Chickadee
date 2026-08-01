// APIServer/Services/WorkerClaimQueue.swift
//
// Application-level claim serializer for runner job claims (split out of
// WorkerJobRoutes.swift in the 0.5 cleanup). One actor per Application,
// seeded eagerly in bootstrapAppDirectories.

import FluentSQLiteDriver
import Vapor

/// Ensures at most one worker-job claim operation executes at a time —
/// **SQLite only** (#1172 moved Postgres to `FOR UPDATE SKIP LOCKED`, which
/// needs no in-process serialization). Claim *correctness* comes from the
/// compare-and-set UPDATE in `atomicallyClaimSubmission` (its
/// `status == pending` guard is atomic); this queue exists so concurrent
/// in-process polls don't thrash SQLite's write lock and burn busy-retries.
/// The section it guards is one UPDATE + one SELECT (2026-07 audit —
/// evaluation moved outside).
///
/// Implemented as a Swift actor — actor isolation replaces the previous
/// NSLock + @unchecked Sendable approach, giving compile-time concurrency
/// safety with no manual lock discipline.
actor WorkerClaimQueue {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var active = false

    func run<T>(_ work: () async throws -> T) async throws -> T {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if active { waiting.append(c) } else { active = true; c.resume() }
        }
        defer { advance() }
        return try await work()
    }

    private func advance() {
        if waiting.isEmpty { active = false } else { waiting.removeFirst().resume() }
    }
}

func retrySQLiteBusyClaim<T>(
    maxAttempts: Int = 3,
    retryDelayNanoseconds: UInt64 = 20_000_000,
    work: @escaping () async throws -> T
) async throws -> T {
    precondition(maxAttempts > 0, "maxAttempts must be positive")

    var attempt = 1
    while true {
        do {
            return try await work()
        } catch {
            guard attempt < maxAttempts, isSQLiteBusyError(error) else {
                throw error
            }
            attempt += 1
            try await Task.sleep(nanoseconds: retryDelayNanoseconds)
        }
    }
}

func isSQLiteBusyError(_ error: Error) -> Bool {
    if let sqliteError = error as? SQLiteError {
        switch sqliteError.reason {
        case .busy, .busyInRecovery, .busyInSnapshot, .busyTimeout:
            return true
        default:
            break
        }
    }

    return error.localizedDescription.localizedCaseInsensitiveContains("database is locked")
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
