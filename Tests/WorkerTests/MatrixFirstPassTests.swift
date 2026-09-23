// Tests/WorkerTests/MatrixFirstPassTests.swift
//
// A folded matrix entry is a first-pass success only when the FOLDED entry
// passed. The mutation sweep of 2026-09-22 (#1574) replaced the `&&` in that
// rule with `||` and nothing failed, so a round robin that the student lost
// could still have been recorded as a first-try pass whenever the first
// opponent happened to be beaten.

import Core
import Foundation
import RunnerCore
import Testing

@testable import chickadee_runner

@Suite struct MatrixFirstPassTests {

    private static func run(_ id: String, _ status: TestStatus) -> MatrixRun {
        MatrixRun(
            opponent: JobOpponent(
                supportFile: nil,
                matchSeed: JobOpponent.matchSeed(submissionID: "s", opponentIdentity: "submission:\(id)"),
                submissionID: id, submissionURL: nil, submissionFilename: "\(id).py"),
            outcomes: [
                TestOutcome(
                    testName: "match", testClass: nil, tier: .pub, status: status,
                    shortResult: status.defaultShortResult, longResult: nil,
                    score: status == .pass ? 1 : 0, points: 1, metric: nil, executionTimeMs: 1,
                    memoryUsageBytes: nil, attemptNumber: 1, isFirstPassSuccess: status == .pass)
            ])
    }

    /// The first opponent was beaten on a first attempt, but two of three
    /// matches were lost, so the entry failed and is no first-pass success.
    @Test func aFailedFoldIsNotAFirstPassSuccessWhateverTheFirstRunSays() throws {
        let runs = [Self.run("a", .pass), Self.run("b", .fail), Self.run("c", .fail)]
        let folded = try #require(aggregateMatrixRuns(runs).first)
        #expect(folded.status == .fail)
        #expect(folded.isFirstPassSuccess == false)
    }

    @Test func aPassedFoldKeepsTheFirstRunsFirstPassSuccess() throws {
        let runs = [Self.run("a", .pass), Self.run("b", .pass), Self.run("c", .fail)]
        let folded = try #require(aggregateMatrixRuns(runs).first)
        #expect(folded.status == .pass)
        #expect(folded.isFirstPassSuccess)
    }
}
