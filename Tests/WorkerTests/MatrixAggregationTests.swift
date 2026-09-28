// Tests/WorkerTests/MatrixAggregationTests.swift
//
// The fold from a matrix job's N runs to one collection plus one report per
// match (docs/class-activities.md, "Round robin"). The collection keeps the
// shape every job reports; the reports carry each match's verdict under
// the identity the server opened its row with.

import Core
import Foundation
import RunnerCore
import Testing

@testable import chickadee_runner

@Suite struct MatrixAggregationTests {

    private func outcome(
        _ name: String, status: TestStatus, score: Double, metric: Double? = nil,
        stderr: String? = nil, timeMs: Int = 10, points: Int = 1
    ) -> TestOutcome {
        TestOutcome(
            testName: name, testClass: nil, tier: .pub, status: status,
            shortResult: status.defaultShortResult, longResult: stderr, score: score, points: points,
            metric: metric, executionTimeMs: timeMs, memoryUsageBytes: nil,
            attemptNumber: 1, isFirstPassSuccess: status == .pass)
    }

    private func opponent(_ id: String) -> JobOpponent {
        JobOpponent(
            supportFile: nil, matchSeed: JobOpponent.matchSeed(submissionID: "s", opponentIdentity: "submission:\(id)"),
            submissionID: id, submissionURL: nil, submissionFilename: "\(id).py")
    }

    @Test func noRunsFoldToNothing() {
        #expect(aggregateMatrixRuns([]).isEmpty)
        #expect(matrixMatchReports([]).isEmpty)
    }

    /// Score is the mean, metric the sum, time the sum, and the entry passes
    /// when at least half the matches did.
    @Test func theFoldAveragesScoreAndSumsMetricAndTime() throws {
        let runs = [
            MatrixRun(
                opponent: opponent("a"), outcomes: [outcome("match", status: .pass, score: 1, metric: 3, timeMs: 10)]),
            MatrixRun(
                opponent: opponent("b"), outcomes: [outcome("match", status: .fail, score: 0, metric: 1, timeMs: 20)]),
            MatrixRun(
                opponent: opponent("c"), outcomes: [outcome("match", status: .pass, score: 1, metric: 2, timeMs: 30)]),
        ]
        let folded = try #require(aggregateMatrixRuns(runs).first)
        #expect(folded.testName == "match")
        #expect(folded.status == .pass)
        #expect(abs(folded.score - 2.0 / 3.0) < 1e-9)
        #expect(folded.metric == 6)
        #expect(folded.executionTimeMs == 60)
        #expect(folded.shortResult == "2/3 matches passed")
        #expect(folded.longResult == nil)
    }

    /// Fewer than half won is a fail; one error or timeout in any run marks
    /// the entry so, because a broken script must never read as a loss.
    @Test func theStatusRules() throws {
        let lose = [
            MatrixRun(opponent: opponent("a"), outcomes: [outcome("m", status: .fail, score: 0)]),
            MatrixRun(opponent: opponent("b"), outcomes: [outcome("m", status: .pass, score: 1)]),
            MatrixRun(opponent: opponent("c"), outcomes: [outcome("m", status: .fail, score: 0)]),
        ]
        #expect(try #require(aggregateMatrixRuns(lose).first).status == .fail)
        let errored = [
            MatrixRun(opponent: opponent("a"), outcomes: [outcome("m", status: .pass, score: 1)]),
            MatrixRun(opponent: opponent("b"), outcomes: [outcome("m", status: .error, score: 0)]),
        ]
        #expect(try #require(aggregateMatrixRuns(errored).first).status == .error)
        let timedOut = [
            MatrixRun(opponent: opponent("a"), outcomes: [outcome("m", status: .pass, score: 1)]),
            MatrixRun(opponent: opponent("b"), outcomes: [outcome("m", status: .timeout, score: 0)]),
        ]
        #expect(try #require(aggregateMatrixRuns(timedOut).first).status == .timeout)
        // Exactly half won passes: a draw against the field is not a loss.
        let half = [
            MatrixRun(opponent: opponent("a"), outcomes: [outcome("m", status: .pass, score: 1)]),
            MatrixRun(opponent: opponent("b"), outcomes: [outcome("m", status: .fail, score: 0)]),
        ]
        #expect(try #require(aggregateMatrixRuns(half).first).status == .pass)
    }

    /// Each run's stderr is kept under a header naming the opponent, so
    /// staff can read every match; a run with no stderr adds no header.
    @Test func stderrIsJoinedUnderOpponentHeaders() throws {
        let runs = [
            MatrixRun(
                opponent: opponent("a"),
                outcomes: [outcome("m", status: .pass, score: 1, stderr: "round 1: paper beats rock")]),
            MatrixRun(opponent: opponent("b"), outcomes: [outcome("m", status: .fail, score: 0)]),
            MatrixRun(
                opponent: opponent("c"),
                outcomes: [outcome("m", status: .pass, score: 1, stderr: "round 1: rock loses")]),
        ]
        let detail = try #require(aggregateMatrixRuns(runs).first?.longResult)
        #expect(detail.contains("--- opponent submission:a ---\nround 1: paper beats rock"))
        #expect(detail.contains("--- opponent submission:c ---\nround 1: rock loses"))
        #expect(!detail.contains("submission:b"))
    }

    /// The fold keeps one outcome per suite entry, in the first run's order,
    /// and an entry a later run never reached is averaged over the runs that
    /// have it. Points and tier come from the first run.
    @Test func entriesKeepTheirOrderAndAMissingEntryIsAveragedOverTheRunsThatHaveIt() throws {
        let runs = [
            MatrixRun(
                opponent: opponent("a"),
                outcomes: [outcome("gate", status: .pass, score: 1, points: 2), outcome("m", status: .pass, score: 1)]),
            MatrixRun(opponent: opponent("b"), outcomes: [outcome("gate", status: .pass, score: 1, points: 2)]),
        ]
        let folded = aggregateMatrixRuns(runs)
        #expect(folded.map(\.testName) == ["gate", "m"])
        #expect(folded[0].points == 2)
        #expect(folded[0].shortResult == "2/2 matches passed")
        let match = try #require(folded.last)
        #expect(match.score == 1)
        #expect(match.shortResult == "1/1 matches passed")
        #expect(match.isFirstPassSuccess)
    }

    /// One report per run, from that run's match entry (the highest-metric
    /// outcome), won iff it passed — the same rule the hill uses.
    @Test func theReportsCarryEachMatchsVerdictUnderItsIdentity() throws {
        let a = opponent("a")
        let b = opponent("b")
        let runs = [
            MatrixRun(
                opponent: a,
                outcomes: [
                    outcome("gate", status: .pass, score: 1), outcome("m", status: .pass, score: 0.8, metric: 4),
                ]),
            MatrixRun(
                opponent: b,
                outcomes: [
                    outcome("gate", status: .pass, score: 1), outcome("m", status: .fail, score: 0.2, metric: 1),
                ]),
            MatrixRun(opponent: opponent("c"), outcomes: [outcome("gate", status: .pass, score: 1)]),
        ]
        let reports = matrixMatchReports(runs)
        #expect(reports.count == 3)
        #expect(reports[0].opponentIdentity == "submission:a")
        #expect(reports[0].opponentSubmissionID == "a")
        #expect(reports[0].seed == a.matchSeed)
        #expect(reports[0].won)
        #expect(reports[0].score == 0.8)
        #expect(reports[0].metric == 4)
        #expect(!reports[1].won)
        #expect(reports[1].seed == b.matchSeed)
        // No match entry (nothing reported a metric): no verdict, not a win.
        let noEntry = try #require(reports.last)
        #expect(!noEntry.won)
        #expect(noEntry.score == nil)
    }
}
