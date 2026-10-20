// Tests/APITests/TestOutcome+Stub.swift
//
// One `TestOutcome` with the values a test does not look at filled in. Use it
// where a test needs an outcome only for its status, score, metric or
// composite, instead of writing the full initializer again.

@testable import Core

extension TestOutcome {

    /// An outcome that ran in 1 ms on its first attempt. `shortResult`
    /// defaults to the status's default text, and `score` to the
    /// initializer's default of 1.
    static func stub(
        _ testName: String = "match",
        tier: TestTier = .pub,
        status: TestStatus = .pass,
        shortResult: String? = nil,
        score: Double = 1,
        metric: Double? = nil,
        composite: CompositeContribution? = nil,
        isFirstPassSuccess: Bool = false
    ) -> TestOutcome {
        TestOutcome(
            testName: testName, testClass: nil, tier: tier, status: status,
            shortResult: shortResult ?? status.defaultShortResult, longResult: nil, score: score, metric: metric,
            composite: composite, executionTimeMs: 1, memoryUsageBytes: nil, attemptNumber: 1,
            isFirstPassSuccess: isFirstPassSuccess)
    }
}
