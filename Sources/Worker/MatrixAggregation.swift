// Worker/MatrixAggregation.swift
//
// A matrix job (round robin, docs/class-activities.md) runs the suite once
// per opponent and reports ONE outcome per suite entry, as every job does —
// `Tests/Fixtures/output-contract.json` never learns a second shape — plus a
// per-match row for each opponent. This file is the fold from N runs to that
// one collection, kept pure so the rule is testable without a daemon.

import Core
import Foundation

/// The N runs of one matrix job, each against one opponent, in the job's
/// opponent order.
struct MatrixRun {
    let opponent: JobOpponent
    let outcomes: [TestOutcome]
}

/// Folds the runs into one outcome per suite entry (by test name, in the
/// order of the first run):
///
/// - `score` is the mean over runs — the win fraction, for the match entry;
/// - `metric` is the sum over runs that reported one (a win count adds up),
///   nil when none did;
/// - `status` is `.error` / `.timeout` if any run was, else `.pass` when the
///   mean score reaches one half (a majority of matches won), else `.fail`;
/// - `executionTimeMs` is the sum, `points` and `tier` the first run's;
/// - `shortResult` counts the runs that passed; `longResult` joins each
///   run's stderr under a header naming the opponent, so staff can read
///   every match (a student's view is the entry's `failureDetail` setting).
///
/// An entry a later run lacks (a script that errored before reaching it) is
/// aggregated over the runs that have it.
func aggregateMatrixRuns(_ runs: [MatrixRun]) -> [TestOutcome] {
    guard let first = runs.first else { return [] }
    return first.outcomes.map { lead in
        let samples = runs.compactMap { run -> (JobOpponent, TestOutcome)? in
            run.outcomes.first { $0.testName == lead.testName }.map { (run.opponent, $0) }
        }
        let count = Double(samples.count)
        let meanScore = samples.map(\.1.score).reduce(0, +) / count
        let metrics = samples.compactMap(\.1.metric)
        let status: TestStatus
        if samples.contains(where: { $0.1.status == .error }) {
            status = .error
        } else if samples.contains(where: { $0.1.status == .timeout }) {
            status = .timeout
        } else {
            status = meanScore >= 0.5 ? .pass : .fail
        }
        let passed = samples.filter { $0.1.status == .pass }.count
        let detail = samples.compactMap { opponent, outcome -> String? in
            guard let text = outcome.longResult, !text.isEmpty else { return nil }
            return "--- opponent \(opponent.identity) ---\n\(text)"
        }
        return TestOutcome(
            testName: lead.testName,
            testClass: lead.testClass,
            tier: lead.tier,
            status: status,
            shortResult: "\(passed)/\(samples.count) matches passed",
            longResult: detail.isEmpty ? nil : detail.joined(separator: "\n"),
            score: meanScore,
            points: lead.points,
            metric: metrics.isEmpty ? nil : metrics.reduce(0, +),
            executionTimeMs: samples.map(\.1.executionTimeMs).reduce(0, +),
            memoryUsageBytes: nil,
            attemptNumber: lead.attemptNumber,
            isFirstPassSuccess: lead.isFirstPassSuccess && status == .pass)
    }
}

/// One `MatchReport` per run, from that run's match entry (`matchOutcome`).
func matrixMatchReports(_ runs: [MatrixRun]) -> [MatchReport] {
    runs.map { run in
        let entry = matchOutcome(from: run.outcomes)
        return MatchReport(
            opponentIdentity: run.opponent.identity,
            opponentSubmissionID: run.opponent.submissionID,
            seed: run.opponent.matchSeed,
            score: entry?.score,
            metric: entry?.metric,
            won: entry?.status == .pass)
    }
}
