// Tests/WorkerTests/CollectionAssemblyTests.swift
//
// `makeCollection` is the fold from a job's outcomes to the collection the
// runner reports (#1799). Its two judgements are the grade (`earnedPoints`,
// weighted by points and aware of partial credit) and the build status (no
// outcomes means the build failed).

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite struct CollectionAssemblyTests {

    private let job = Job(
        submissionID: "sub_1",
        testSetupID: "ts_1",
        attemptNumber: 3,
        submissionURL: testURL("https://server.test/sub.zip"),
        testSetupURL: testURL("https://server.test/ts.zip"),
        manifest: TestProperties(language: nil), language: nil
    )

    private func outcome(
        _ name: String, status: TestStatus, score: Double, points: Int = 1, timeMs: Int = 10
    ) -> TestOutcome {
        TestOutcome(
            testName: name, testClass: nil, tier: .pub, status: status,
            shortResult: status.defaultShortResult, longResult: nil, score: score, points: points,
            executionTimeMs: timeMs, memoryUsageBytes: nil, attemptNumber: 3,
            isFirstPassSuccess: false)
    }

    private func collect(_ outcomes: [TestOutcome]) -> TestOutcomeCollection {
        makeCollection(
            outcomes: outcomes, warnings: ["a warning"], job: job,
            startedAt: Date(timeIntervalSince1970: 100), finishedAt: Date(timeIntervalSince1970: 200))
    }

    /// Points times score for each outcome: a partial score counts for its
    /// share of the test's points, on a pass or on a fail.
    @Test func earnedPointsWeighsEachScoreByItsPoints() {
        let collection = collect([
            outcome("full", status: .pass, score: 1, points: 2),
            outcome("partial", status: .fail, score: 0.25, points: 4),
            outcome("none", status: .fail, score: 0, points: 3),
        ])
        #expect(collection.totalPoints == 9)
        #expect(collection.earnedPoints == 3.0)
    }

    @Test func eachStatusIsCountedOnceAndTheTimesAreSummed() {
        let collection = collect([
            outcome("a", status: .pass, score: 1, timeMs: 5),
            outcome("b", status: .pass, score: 1, timeMs: 7),
            outcome("c", status: .fail, score: 0, timeMs: 11),
            outcome("d", status: .error, score: 0, timeMs: 13),
            outcome("e", status: .timeout, score: 0, timeMs: 17),
        ])
        #expect(collection.totalTests == 5)
        #expect(collection.passCount == 2)
        #expect(collection.failCount == 1)
        #expect(collection.errorCount == 1)
        #expect(collection.timeoutCount == 1)
        #expect(collection.executionTimeMs == 53)
    }

    @Test func outcomesMeanTheBuildPassed() {
        #expect(collect([outcome("a", status: .fail, score: 0)]).buildStatus == .passed)
    }

    @Test func noOutcomesMeanTheBuildFailed() {
        let collection = collect([])
        #expect(collection.buildStatus == .failed)
        #expect(collection.totalTests == 0)
        #expect(collection.earnedPoints == 0)
    }

    @Test func theJobAndTheTimesAreCarriedThrough() {
        let collection = collect([outcome("a", status: .pass, score: 1)])
        #expect(collection.submissionID == "sub_1")
        #expect(collection.testSetupID == "ts_1")
        #expect(collection.attemptNumber == 3)
        #expect(collection.warnings == ["a warning"])
        #expect(collection.jobStartedAt == Date(timeIntervalSince1970: 100))
        #expect(collection.timestamp == Date(timeIntervalSince1970: 200))
        #expect(collection.runnerVersion == ChickadeeVersion.current)
    }
}
