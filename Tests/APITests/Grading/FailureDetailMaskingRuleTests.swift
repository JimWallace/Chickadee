// Tests/APITests/Grading/FailureDetailMaskingRuleTests.swift
//
// The parts of FailureDetailMasking.swift that FailureDetailMaskingTests does
// not reach without a database: a headline behind a test-label prefix,
// which outcomes `maskingFailureDetail` touches, and the order of
// `failureDetailFingerprint`. Added to answer the mutation survivors of the
// 2026-11-13 APIServer run.

import Foundation
import Testing

@testable import APIServer
@testable import Core

@Suite struct FailureDetailMaskingRuleTests {

    private static let failureText = """
        wrong value
          input:    classify(3)
          expected: 'ANSWER'
          got:      'GUESS'
        """

    private static func outcome(_ name: String, status: TestStatus, shortResult: String) -> TestOutcome {
        TestOutcome(
            testName: name, testClass: nil, tier: .pub, status: status,
            shortResult: shortResult, longResult: status == .pass ? nil : failureText,
            score: status == .pass ? 1 : 0, points: 1, executionTimeMs: 3,
            memoryUsageBytes: nil, attemptNumber: 1, isFirstPassSuccess: false)
    }

    // MARK: - The headline

    @Test func aHeadlineBehindATestLabelIsKept() {
        // Only the text after the colon is a known headline; the whole line
        // is not. The footer copy is the only copy, so it is the one read.
        let short = "Case 3: wrong value\n  expected: 'ANSWER'\n  got:      'GUESS'"
        let masked = maskFailureOutput(
            shortResult: short, longResult: nil, status: .fail, detail: .actualOnly)
        #expect(masked.shortResult == "Case 3: wrong value")
        #expect(masked.longResult == "  got:      'GUESS'")
    }

    // MARK: - maskingFailureDetail

    @Test func onlyAFailingOutcomeWithARestrictiveSettingIsMasked() {
        let outcomes = [
            Self.outcome("masked", status: .fail, shortResult: "masked: wrong value"),
            Self.outcome("passing", status: .pass, shortResult: "passed"),
            Self.outcome("unrestricted", status: .fail, shortResult: "unrestricted: wrong value"),
            Self.outcome("unlisted", status: .fail, shortResult: "unlisted: wrong value"),
        ]
        let result = maskingFailureDetail(
            of: outcomes,
            failureDetailByFilename: [
                "masked": .verdictOnly, "passing": .verdictOnly, "unrestricted": .full,
            ])
        #expect(result.map(\.testName) == ["masked", "passing", "unrestricted", "unlisted"])
        #expect(result[0].shortResult == "did not pass")
        #expect(result[0].longResult == nil)
        #expect(result[1].shortResult == "passed")
        #expect(result[2].shortResult == "unrestricted: wrong value")
        #expect(result[2].longResult == Self.failureText)
        #expect(result[3].shortResult == "unlisted: wrong value")
        #expect(result[3].longResult == Self.failureText)
    }

    @Test func aSkippedOutcomeIsNotMasked() {
        let skipped = skippedPrerequisiteMessage(prerequisite: "first.py")
        let result = maskingFailureDetail(
            of: [Self.outcome("second", status: .fail, shortResult: skipped)],
            failureDetailByFilename: ["second": .verdictOnly])
        #expect(result.first?.shortResult == skipped)
    }

    // MARK: - failureDetailFingerprint

    @Test func theFingerprintListsTheEntriesInFilenameOrder() {
        let fingerprint = failureDetailFingerprint([
            "c.py": .full, "a.py": .verdictOnly, "b.py": .actualOnly,
        ])
        #expect(fingerprint == "a.py=verdictOnly;b.py=actualOnly;c.py=full")
        #expect(failureDetailFingerprint([:]).isEmpty)
    }
}
