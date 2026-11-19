// Tests/APITests/Pages/MaskedSecretRowPointsTests.swift
//
// `maskedSecretRows` builds the rows for secret tests on the student
// submission page. The rows hide the test name, the output and the hint, but
// they still show the credit. The partial-credit label ("1.5 / 3 pts") had no
// test, and neither had the rule that a full or zero score shows the plain
// weight only on a weighted assignment.

import Core
import Testing

@testable import APIServer

@Suite struct MaskedSecretRowPointsTests {

    private func outcome(
        _ name: String, status: TestStatus = .fail, score: Double, points: Int
    ) -> TestOutcome {
        TestOutcome(
            testName: name, testClass: nil, tier: .secret, status: status,
            shortResult: "expected 42, got 7", longResult: "the full trace",
            score: score, points: points, executionTimeMs: 1, memoryUsageBytes: nil,
            attemptNumber: 1, isFirstPassSuccess: false)
    }

    @Test func partialCreditShowsTheEarnedFractionOfThePoints() {
        let rows = maskedSecretRows(
            [
                outcome("secret_a", score: 0.5, points: 3),
                outcome("secret_b", score: 0.25, points: 1),
                outcome("secret_c", score: 1.0 / 3.0, points: 2),
            ], weighted: false)
        #expect(rows.map(\.pointsLabel) == ["1.5 / 3 pts", "0.25 / 1 pt", "0.67 / 2 pts"])
    }

    @Test func fullOrZeroCreditShowsTheWeightOnlyOnAWeightedAssignment() {
        let outcomes = [
            outcome("secret_a", status: .pass, score: 1, points: 3),
            outcome("secret_b", status: .fail, score: 0, points: 3),
            outcome("secret_c", status: .pass, score: 1, points: 1),
        ]
        #expect(maskedSecretRows(outcomes, weighted: true).map(\.pointsLabel) == ["3 pts", "3 pts", nil])
        #expect(maskedSecretRows(outcomes, weighted: false).map(\.pointsLabel) == [nil, nil, nil])
    }

    @Test func aMaskedRowNamesNoTestAndShowsNoOutput() {
        let rows = maskedSecretRows(
            [outcome("secret_a", status: .timeout, score: 0.5, points: 2), outcome("secret_b", score: 0, points: 1)],
            weighted: true)
        #expect(rows.map(\.testName) == ["hidden test 1", "hidden test 2"])
        #expect(rows.allSatisfy { $0.tier == TestTier.secret.rawValue })
        #expect(rows.allSatisfy { $0.longResult == nil && $0.hint == nil && $0.blockerName == nil })
        #expect(rows.map(\.shortResult) == ["did not pass", "did not pass"])
        #expect(rows.map(\.markLabel) == ["Timeout", "Fail"])
        #expect(rows.map(\.markClass) == ["timeout", "fail"])
    }
}
