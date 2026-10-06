// Tests/APITests/DeployerHealthRuleTests.swift
//
// The `deployerUnhealthy` rule reads the status file the deploy daemon writes.
// It fires when the daemon reports that it is stuck, failing or serving an
// invalid certificate, and when the daemon has stopped writing its status. It
// stays quiet where there is no daemon, and while an operator has paused it.

import Foundation
import Testing

@testable import APIServer

@Suite struct DeployerHealthRuleTests {

    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    private func status(
        state: String, minutesAgo: Double = 1, paused: Bool = false, detail: String? = "detail"
    ) -> DeployerStatus {
        let updated = ISO8601DateFormatter().string(from: now.addingTimeInterval(-minutesAgo * 60))
        return DeployerStatus(
            state: state, detail: detail, deployedVersion: "0.5.463", latestSeen: "v0.5.464",
            paused: paused, updatedAt: updated)
    }

    @Test func noStatusFileIsNotAFiringCondition() {
        #expect(!decideDeployerUnhealthy(status: nil, now: now).isFiring)
    }

    @Test(arguments: ["idle", "deploying", "waiting_for_image", "pending_approval"])
    func aRecentStatusInAWorkingStateDoesNotFire(state: String) {
        #expect(!decideDeployerUnhealthy(status: status(state: state), now: now).isFiring)
    }

    @Test(arguments: ["stuck", "error", "certificate_invalid"])
    func anUnhealthyStateFiresWithItsDetail(state: String) {
        let evaluation = decideDeployerUnhealthy(
            status: status(state: state, detail: "deploy of v0.5.464 has failed 5 times"), now: now)
        #expect(evaluation.isFiring)
        #expect(evaluation.summary.contains(state))
        #expect(evaluation.summary.contains("failed 5 times"))
        #expect(evaluation.details["latest_seen"] == "v0.5.464")
    }

    @Test func aStatusOlderThanThirtyMinutesFiresAsAStoppedDaemon() {
        let evaluation = decideDeployerUnhealthy(status: status(state: "idle", minutesAgo: 45), now: now)
        #expect(evaluation.isFiring)
        #expect(evaluation.summary.contains("45 min"))
        #expect(!decideDeployerUnhealthy(status: status(state: "idle", minutesAgo: 25), now: now).isFiring)
    }

    @Test func aPausedDaemonDoesNotFireHowEverOld() {
        let evaluation = decideDeployerUnhealthy(
            status: status(state: "paused", minutesAgo: 600, paused: true), now: now)
        #expect(!evaluation.isFiring)
    }

    @Test func theRuleIsAWarningThatPages() {
        #expect(HealthRule.deployerUnhealthy.severity == "warning")
        #expect(HealthRule.deployerUnhealthy.pagesOperator)
    }
}
