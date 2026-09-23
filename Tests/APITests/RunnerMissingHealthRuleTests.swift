// Tests/APITests/RunnerMissingHealthRuleTests.swift
//
// The rule that would have caught the Sept 2026 sparrow outage. One runner lost
// its network for several days while two others kept polling, so `runnerOffline`
// ("is ANY runner checking in?") stayed green, and each daily deploy erased the
// in-memory activity store. These tests pin the three things that distinguish
// the new rule: it names ONE quiet runner even while others poll, it remembers
// runners across restarts by reading `runner_snapshots`, and it ignores the
// container-derived IDs that change on every compose redeploy.

import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.timeLimit(.minutes(2))) struct RunnerMissingHealthRuleTests {

    private let offlineSeconds: TimeInterval = 300
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ago(_ seconds: TimeInterval) -> Date {
        now.addingTimeInterval(-seconds)
    }

    // MARK: - Generated IDs

    @Test(arguments: ["runner-67b6e9d08460", "runner-0123456789ab"])
    func composeGeneratedIDsAreRecognized(_ runnerID: String) {
        #expect(isGeneratedRunnerID(runnerID))
    }

    @Test(arguments: [
        "Sparrow", "runner-01", "runner-67B6E9D08460", "runner-67b6e9d0846", "runner-67b6e9d08460x",
        "runner-67b6e9d0846g",
    ])
    func operatorChosenIDsAreNotGenerated(_ runnerID: String) {
        #expect(!isGeneratedRunnerID(runnerID))
    }

    // MARK: - The decision

    @Test func itFiresForOneQuietRunnerWhileOthersPoll() {
        let evaluation = decideRunnersMissing(
            lastSeenByRunner: [
                "Chickadee": ago(5),
                "Sparrow": ago(5 * 86_400 + 13 * 3600),
                "Starling": ago(10),
            ],
            offlineSeconds: offlineSeconds,
            now: now
        )
        #expect(evaluation.isFiring)
        #expect(evaluation.summary == "Runners not polling: Sparrow for 5d 13h")
        #expect(evaluation.details["missing_runners"] == "Sparrow")
        #expect(evaluation.details["runner_offline_threshold_seconds"] == "300")
    }

    @Test func itNamesEveryQuietRunnerInOrder() {
        let evaluation = decideRunnersMissing(
            lastSeenByRunner: ["Starling": ago(2 * 3600 + 5 * 60), "Sparrow": ago(45 * 60)],
            offlineSeconds: offlineSeconds,
            now: now
        )
        #expect(evaluation.summary == "Runners not polling: Sparrow for 45m, Starling for 2h 5m")
        #expect(evaluation.details["missing_runners"] == "Sparrow, Starling")
    }

    @Test func itStaysGreenWhenEveryRunnerPolledWithinTheThreshold() {
        let evaluation = decideRunnersMissing(
            lastSeenByRunner: ["Sparrow": ago(offlineSeconds), "Starling": ago(1)],
            offlineSeconds: offlineSeconds,
            now: now
        )
        #expect(!evaluation.isFiring)
    }

    @Test func itIgnoresAComposeRunnerReplacedByARedeploy() {
        let evaluation = decideRunnersMissing(
            lastSeenByRunner: ["runner-67b6e9d08460": ago(3600), "runner-efd640eccf8e": ago(5)],
            offlineSeconds: offlineSeconds,
            now: now
        )
        #expect(!evaluation.isFiring)
    }

    @Test func itForgetsARunnerAfterTheRememberWindow() {
        let evaluation = decideRunnersMissing(
            lastSeenByRunner: ["Retired": ago(runnerMissingRememberSeconds + 60)],
            offlineSeconds: offlineSeconds,
            now: now
        )
        #expect(!evaluation.isFiring)
    }

    @Test func itStaysGreenWhenNoRunnerWasEverRecorded() {
        let evaluation = decideRunnersMissing(lastSeenByRunner: [:], offlineSeconds: offlineSeconds, now: now)
        #expect(!evaluation.isFiring)
    }

    @Test func theRuleWarnsAndPages() {
        #expect(HealthRule.runnerMissing.severity == "warning")
        #expect(HealthRule.runnerMissing.pagesOperator)
    }

    // MARK: - Persistence

    private func recordSnapshot(_ runnerID: String, at date: Date, on app: Application) async throws {
        let row = RunnerSnapshot(
            runnerID: runnerID,
            recordedAt: date,
            activeJobs: 0,
            maxJobs: 6,
            availableCapacity: 6,
            hostname: nil,
            runnerVersion: nil,
            lastPollAt: date,
            lastHeartbeatAt: nil,
            serverAssignedJobCountSinceStart: nil
        )
        try await row.save(on: app.db)
    }

    @Test func itReadsTheNewestSnapshotPerRunnerInsideTheWindow() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            try await recordSnapshot("Sparrow", at: ago(3 * 86_400), on: app)
            try await recordSnapshot("Sparrow", at: ago(2 * 86_400), on: app)
            try await recordSnapshot("Starling", at: ago(30), on: app)
            try await recordSnapshot("Retired", at: ago(runnerMissingRememberSeconds + 3600), on: app)

            let lastSeen = try await loadRunnerLastSeen(on: app.db, now: now)

            #expect(Set(lastSeen.keys) == ["Sparrow", "Starling"])
            let sparrow = try #require(lastSeen["Sparrow"])
            let starling = try #require(lastSeen["Starling"])
            #expect(abs(sparrow.timeIntervalSince(ago(2 * 86_400))) < 1)
            #expect(abs(starling.timeIntervalSince(ago(30))) < 1)
        }
    }

    @Test func theEvaluatorFiresFromPersistedSnapshotsAlone() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            // Nothing is in the in-memory activity store, as after a restart.
            try await recordSnapshot("Sparrow", at: ago(86_400), on: app)
            try await recordSnapshot("Starling", at: ago(10), on: app)

            let results = await evaluateHealthRules(
                on: app,
                configuration: .default,
                now: now
            )

            let evaluation = try #require(results[.runnerMissing])
            #expect(evaluation.isFiring)
            #expect(evaluation.details["missing_runners"] == "Sparrow")
        }
    }
}
