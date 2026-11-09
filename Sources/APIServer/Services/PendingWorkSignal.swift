// APIServer/Services/PendingWorkSignal.swift
//
// Wakes the runner polls that the server holds open (`WorkerLongPoll`). A
// runner slot with no job asks the server to hold its poll; the poll handler
// waits here between claim attempts. Two things wake it:
//
//  - `notify()`, which `SubmissionIntake` calls once a student submission's
//    row is committed. That is the path a student waits on, so it wakes the
//    held polls at once.
//  - A watcher that counts the pending rows once a second while any poll is
//    held, and wakes the polls when the count grows. It covers every other
//    way a row becomes pending (validation runs, retests, the stuck-claim
//    reaper, a second server process during a blue-green cutover) without a
//    hook at each site. It runs only while a poll is held, so a server with
//    no runner waiting reads nothing.
//
// `close()` releases every held poll at shutdown. Vapor runs the lifecycle
// handlers before it waits for in-flight requests, so a held poll does not
// hold up a deploy's drain.

import Fluent
import Foundation
import Vapor

actor PendingWorkSignal {
    /// Counts the pending submissions. The watcher compares one count with
    /// the next.
    typealias PendingCount = @Sendable () async throws -> Int

    private let pendingCount: PendingCount
    private let watchInterval: Duration
    private var generation: UInt64 = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var watcher: Task<Void, Never>?

    /// True once `close()` has run. A closed signal holds no poll.
    private(set) var isClosed = false

    init(watchInterval: Duration = .seconds(1), pendingCount: @escaping PendingCount) {
        self.watchInterval = watchInterval
        self.pendingCount = pendingCount
    }

    /// Changes each time pending work may have appeared. A poll reads it
    /// before its claim attempt and then waits for it to change, so a
    /// submission that arrives during the claim walk is not missed.
    var currentGeneration: UInt64 { generation }

    /// How many polls are held now.
    var heldCount: Int { waiters.count }

    /// Wakes every held poll to try a claim again.
    func notify() {
        generation &+= 1
        resumeAll()
    }

    /// Returns when the generation moves past `seen`, when `deadline` passes,
    /// or when the signal closes, whichever is first. Returns at once if any
    /// of those has already happened.
    ///
    /// A cancelled caller still waits for one of the three: the deadline
    /// bounds the wait, and Vapor does not cancel a handler when its client
    /// goes away.
    func wait(after seen: UInt64, until deadline: ContinuousClock.Instant) async {
        guard !isClosed, generation == seen, ContinuousClock.now < deadline else { return }
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            await self?.release(id)
        }
        await withCheckedContinuation { continuation in
            waiters[id] = continuation
            startWatcherIfNeeded()
        }
        timer.cancel()
    }

    /// Releases every held poll, holds no new one, and stops the watcher.
    /// Returns after the watcher's last count, so no count reads the
    /// database after this returns.
    func close() async {
        isClosed = true
        resumeAll()
        let running = watcher
        watcher = nil
        running?.cancel()
        await running?.value
    }

    private func release(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }

    private func resumeAll() {
        let held = waiters
        waiters.removeAll()
        for continuation in held.values {
            continuation.resume()
        }
    }

    private func startWatcherIfNeeded() {
        guard watcher == nil, !isClosed else { return }
        watcher = Task { [pendingCount, watchInterval] in
            // The count when the first poll began to wait. A pending row
            // that is already there did not wake that poll's claim, so only
            // a rise in the count is news.
            var lastCount = try? await pendingCount()
            while true {
                try? await Task.sleep(for: watchInterval)
                guard self.keepWatching() else { return }
                guard let count = try? await pendingCount() else { continue }
                if let lastCount, count > lastCount {
                    self.notify()
                }
                lastCount = count
            }
        }
    }

    /// Whether the watcher should count again. When it should not, the
    /// watcher ends, and this clears it in the same step, so the next held
    /// poll starts a new one.
    private func keepWatching() -> Bool {
        guard !isClosed, !waiters.isEmpty else {
            watcher = nil
            return false
        }
        return true
    }
}

/// Closes `Application.pendingWorkSignal` at shutdown.
///
/// Vapor runs `shutdownAsync` handlers in reverse registration order, and
/// `bootstrapAppServices` registers this one after Fluent's, so the watcher's
/// last count runs while `application.db` is still open. The handlers run
/// before Vapor stops the HTTP server, which waits for in-flight requests, so
/// the held polls answer first.
struct PendingWorkSignalLifecycleHandler: LifecycleHandler {
    func shutdownAsync(_ application: Application) async {
        await application.pendingWorkSignal.close()
    }
}

struct PendingWorkSignalKey: StorageKey {
    typealias Value = PendingWorkSignal
}

extension Application {
    /// The one signal for this application's held runner polls. The watcher
    /// holds the application weakly, so the signal does not keep it alive.
    var pendingWorkSignal: PendingWorkSignal {
        get {
            lazyStored(PendingWorkSignalKey.self) {
                PendingWorkSignal { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await WorkerJobClaim.pendingCount(on: db)
                }
            }
        }
        set { storage[PendingWorkSignalKey.self] = newValue }
    }
}
