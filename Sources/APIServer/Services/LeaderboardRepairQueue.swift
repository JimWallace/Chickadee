// APIServer/Services/LeaderboardRepairQueue.swift
//
// Schedules `repairLeaderboardEntries` after a failed leaderboard write, one
// repair per assignment at a time.
//
// The failures this is for come in bursts: a whole class submits, the
// database pool runs short, and several writes fail together. Each failure
// asks for a repair, and every ask that arrives while a repair is waiting to
// start joins it, so a burst costs one repair rather than one per student. The
// repair waits first (the burst that caused the failure is usually over a few
// seconds later), and a repair that fails is tried again after a longer wait.
//
// A failure that arrives after a repair has STARTED schedules another one: the
// running repair may already have read past that student's result.
//
// In-process only, like `ClassRecordRecomputeQueue`. A server restarted while a
// repair is waiting drops it, and the next failed write for that assignment
// schedules a new one.

import Foundation
import Logging
import Vapor

actor LeaderboardRepairQueue {

    /// How long each attempt waits before it runs. The first lets the burst
    /// that caused the failure pass, so the repair (which reads every stored
    /// collection of the assignment) does not compete with it for the pool;
    /// the rest back off. About seven and a half minutes in all.
    static let defaultDelays: [Duration] = [.seconds(30), .seconds(60), .seconds(120), .seconds(240)]

    private let delays: [Duration]
    /// Assignments with a repair scheduled that has not started yet.
    private var waiting: Set<String> = []

    init(delays: [Duration] = LeaderboardRepairQueue.defaultDelays) {
        self.delays = delays
    }

    /// Schedules `repair` for `key`, unless a repair for it is already waiting
    /// to start. Returns the task that runs it, or nil when this call joined
    /// the waiting one. The caller does not wait for it.
    @discardableResult
    func schedule(
        _ key: String, logger: Logger, _ repair: @escaping @Sendable () async throws -> Void
    ) -> Task<Void, Never>? {
        guard waiting.insert(key).inserted else { return nil }
        let delays = self.delays
        return Task {
            for (attempt, delay) in delays.enumerated() {
                try? await Task.sleep(for: delay)
                self.markStarted(key)
                do {
                    try await repair()
                    logger.info("leaderboard_repair_done for \(key) on attempt \(attempt + 1)")
                    return
                } catch {
                    logger.warning("leaderboard_repair_failed for \(key) on attempt \(attempt + 1): \(error)")
                    // A failure since this attempt started scheduled its own
                    // repair, which reads everything again: leave it to that.
                    guard self.rejoin(key) else { return }
                }
            }
            self.markStarted(key)
            logger.error("leaderboard_repair_gave_up for \(key) after \(delays.count) attempts")
        }
    }

    /// Whether a repair for `key` is waiting to start.
    func isWaiting(_ key: String) -> Bool {
        waiting.contains(key)
    }

    private func markStarted(_ key: String) {
        waiting.remove(key)
    }

    /// Marks `key` waiting again for the next attempt; false when another
    /// repair is already waiting.
    private func rejoin(_ key: String) -> Bool {
        waiting.insert(key).inserted
    }
}

struct LeaderboardRepairQueueKey: StorageKey {
    typealias Value = LeaderboardRepairQueue
}

extension Application {
    var leaderboardRepairQueue: LeaderboardRepairQueue {
        lazyStored(LeaderboardRepairQueueKey.self) { LeaderboardRepairQueue() }
    }
}
