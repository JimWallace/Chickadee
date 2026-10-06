// Tests/APITests/RunnerTargetGateTests.swift
//
// A job that asks for one runner waits for it, and only up to the fallback
// time. After that any runner may claim it, so a target cannot strand a job.

import Foundation
import Testing

@testable import APIServer

@Suite struct RunnerTargetGateTests {
    private let queued = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aJobWithNoTargetIsOpenToEveryRunner() {
        #expect(RunnerTargetGate.allows(targetRunnerID: nil, queuedAt: queued, runnerID: "Sparrow", now: queued))
    }

    @Test func theTargetMayClaimAtOnce() {
        #expect(
            RunnerTargetGate.allows(targetRunnerID: "Starling", queuedAt: queued, runnerID: "Starling", now: queued))
    }

    @Test func anotherRunnerWaitsUntilTheFallbackTime() {
        let justBefore = queued.addingTimeInterval(RunnerTargetGate.fallbackSeconds - 1)
        #expect(
            !RunnerTargetGate.allows(targetRunnerID: "Starling", queuedAt: queued, runnerID: "Sparrow", now: justBefore)
        )
    }

    @Test func anotherRunnerMayClaimAfterTheFallbackTime() {
        let atFallback = queued.addingTimeInterval(RunnerTargetGate.fallbackSeconds)
        #expect(
            RunnerTargetGate.allows(targetRunnerID: "Starling", queuedAt: queued, runnerID: "Sparrow", now: atFallback))
    }

    /// With no queue time there is no wait to measure, so the job must not
    /// wait for ever.
    @Test func aTargetedJobWithNoQueueTimeIsOpenToEveryRunner() {
        #expect(RunnerTargetGate.allows(targetRunnerID: "Starling", queuedAt: nil, runnerID: "Sparrow", now: queued))
    }

    @Test func onlyAnotherRunnerClaimingATargetedJobIsAFallback() {
        #expect(RunnerTargetGate.isFallback(targetRunnerID: "Starling", runnerID: "Sparrow"))
        #expect(!RunnerTargetGate.isFallback(targetRunnerID: "Starling", runnerID: "Starling"))
        #expect(!RunnerTargetGate.isFallback(targetRunnerID: nil, runnerID: "Sparrow"))
    }
}
