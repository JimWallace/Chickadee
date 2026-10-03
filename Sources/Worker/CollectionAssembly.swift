// Worker/CollectionAssembly.swift
//
// The fold from a job's outcomes to the collection the runner reports: the
// four status counts, the total time, and the points. Kept pure, beside
// `MatrixAggregation.swift`, so the rule is tested without a daemon (#1799).

import Core
import Foundation

/// Builds the collection a job reports from its outcomes.
///
/// `earnedPoints` is weighted and aware of partial credit: `points × score`
/// for each outcome. A script with no footer `score` scores 1 on a pass and 0
/// otherwise, so for a suite without partial credit this equals the sum of
/// the points of the tests that passed.
///
/// No outcomes means the build failed (`buildStatus: .failed`): the suite
/// never ran, so there is nothing to grade.
func makeCollection(
    outcomes: [TestOutcome],
    warnings: [String],
    job: Job,
    startedAt: Date,
    finishedAt: Date
) -> TestOutcomeCollection {
    // One pass over the outcomes instead of six (4 × filter().count +
    // 2 × reduce) — the codebase's own stated antipattern.
    var passCount = 0
    var failCount = 0
    var errorCount = 0
    var timeoutCount = 0
    var totalMs = 0
    var totalPoints = 0
    var earnedPoints = 0.0
    for outcome in outcomes {
        switch outcome.status {
        case .pass: passCount += 1
        case .fail: failCount += 1
        case .error: errorCount += 1
        case .timeout: timeoutCount += 1
        }
        totalMs += outcome.executionTimeMs
        totalPoints += outcome.points
        earnedPoints += Double(outcome.points) * outcome.score
    }

    let buildStatus: BuildStatus = outcomes.isEmpty ? .failed : .passed

    return TestOutcomeCollection(
        submissionID: job.submissionID,
        testSetupID: job.testSetupID,
        attemptNumber: job.attemptNumber,
        buildStatus: buildStatus,
        compilerOutput: nil,
        outcomes: outcomes,
        totalTests: outcomes.count,
        passCount: passCount,
        failCount: failCount,
        errorCount: errorCount,
        timeoutCount: timeoutCount,
        executionTimeMs: totalMs,
        totalPoints: totalPoints,
        earnedPoints: earnedPoints,
        warnings: warnings,
        jobStartedAt: startedAt,
        runnerVersion: ChickadeeVersion.current,
        timestamp: finishedAt
    )
}
