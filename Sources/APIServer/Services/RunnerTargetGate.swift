// APIServer/Services/RunnerTargetGate.swift
//
// Whether a runner may claim a job that asks for one runner. Staff ask for a
// runner to see how it grades a suite (MCP `run_validation`), for example after
// a change to one host. The target is a preference, not a pin: for
// `fallbackSeconds` after the job is queued only the named runner may claim it,
// and after that any runner may. So a target that is offline, asleep or
// misspelled delays the job, and never strands it.
//
// It is separate from `claimCompatibility` on purpose. That function decides
// whether a runner CAN grade a job, and the unclaimable-jobs health rule reads
// it. A target decides only which compatible runner goes first, and a targeted
// job is never unclaimable.

import Foundation

enum RunnerTargetGate {
    /// How long only the target may claim a job. Five minutes: long enough
    /// for an idle runner's next poll, short enough that the job still runs
    /// before the unclaimable-jobs alert would report it.
    static let fallbackSeconds: TimeInterval = 300

    /// Whether `runnerID` may claim a job with `targetRunnerID`, queued at
    /// `queuedAt`. A job with no target, or with no queue time to measure the
    /// wait from, is open to every runner.
    static func allows(
        targetRunnerID: String?, queuedAt: Date?, runnerID: String, now: Date
    ) -> Bool {
        guard let targetRunnerID, targetRunnerID != runnerID, let queuedAt else { return true }
        return now.timeIntervalSince(queuedAt) >= fallbackSeconds
    }

    /// Whether `runnerID` claiming the job means the target was not honoured:
    /// a target was set, and another runner claimed the job after the wait.
    static func isFallback(targetRunnerID: String?, runnerID: String) -> Bool {
        guard let targetRunnerID else { return false }
        return targetRunnerID != runnerID
    }
}
