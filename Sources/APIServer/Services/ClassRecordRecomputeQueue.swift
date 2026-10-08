// APIServer/Services/ClassRecordRecomputeQueue.swift
//
// Runs class-record recomputes one at a time per assignment (#2468).
//
// A recompute reads every submission's latest result and then writes the
// holders. Two at once can interleave: one reads before the other's result is
// stored and writes after it, so the stale answer wins. A retest-all makes
// exactly that happen, because its results arrive together.
//
// So runs for one assignment are serialized, and a caller that arrives while a
// run is queued but not yet started joins that run instead of adding another.
// That queued run starts after the caller's result is stored, so it sees it,
// and a retest-all costs a few recomputes rather than one per submission.
//
// This serializes within one server process. Two processes overlap only for a
// moment during a blue-green cutover, and the next retest result corrects any
// record written then.

import Vapor

actor ClassRecordRecomputeQueue {

    /// The last run for each assignment, running or queued.
    private var tails: [String: Task<Void, Never>] = [:]
    /// A run that is queued and has not started yet.
    private var queued: [String: Task<Void, Never>] = [:]

    /// Runs `work` for `key` after the run in progress, and returns when the
    /// run that covers this call has finished.
    func run(_ key: String, _ work: @escaping @Sendable () async -> Void) async {
        if let waiting = queued[key] {
            await waiting.value
            return
        }
        let previous = tails[key]
        let task = Task {
            await previous?.value
            self.markStarted(key)
            await work()
        }
        queued[key] = task
        tails[key] = task
        await task.value
        if tails[key] == task { tails[key] = nil }
    }

    private func markStarted(_ key: String) {
        queued[key] = nil
    }
}

struct ClassRecordRecomputeQueueKey: StorageKey {
    typealias Value = ClassRecordRecomputeQueue
}

extension Application {
    var classRecordRecomputeQueue: ClassRecordRecomputeQueue {
        lazyStored(ClassRecordRecomputeQueueKey.self) { ClassRecordRecomputeQueue() }
    }
}
