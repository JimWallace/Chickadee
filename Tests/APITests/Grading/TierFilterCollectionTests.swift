// Tests/APITests/Grading/TierFilterCollectionTests.swift
//
// The collection helpers in TierFilter.swift that TierFilterTests does not
// reach: `filtering(tiers:)` recomputes every aggregate from the outcomes
// that survive, `replacingOutcomes(with:)` keeps every aggregate as it was,
// `decodedCollection(from:)` reads a stored collection, and the release
// gates open at the deadline itself, not one instant after it. Added to
// answer the mutation survivors of the 2026-11-13 APIServer run.

import Foundation
import Testing

@testable import APIServer
@testable import Core

@Suite struct TierFilterCollectionTests {

    private static let started = Date(timeIntervalSince1970: 1_700_000_000)
    private static let stamped = Date(timeIntervalSince1970: 1_700_000_100)

    private static func outcome(
        _ name: String, tier: TestTier, status: TestStatus, score: Double, points: Int
    ) -> TestOutcome {
        TestOutcome(
            testName: name, testClass: nil, tier: tier, status: status,
            shortResult: status.rawValue, longResult: nil, score: score, points: points,
            executionTimeMs: 5, memoryUsageBytes: nil, attemptNumber: 1,
            isFirstPassSuccess: false)
    }

    /// Six outcomes over three tiers, with distinct points and scores so that
    /// each aggregate has one right value only.
    private static let collection = TestOutcomeCollection(
        submissionID: "sub-1", testSetupID: "setup-1", attemptNumber: 4,
        buildStatus: .passed, compilerOutput: "warning: unused",
        outcomes: [
            outcome("pub_pass", tier: .pub, status: .pass, score: 1, points: 2),
            outcome("pub_fail", tier: .pub, status: .fail, score: 0.25, points: 4),
            outcome("rel_error", tier: .release, status: .error, score: 0, points: 8),
            outcome("rel_timeout", tier: .release, status: .timeout, score: 0, points: 16),
            outcome("rel_pass", tier: .release, status: .pass, score: 0.5, points: 32),
            outcome("sec_pass", tier: .secret, status: .pass, score: 1, points: 64),
        ],
        totalTests: 6, passCount: 3, failCount: 1, errorCount: 1, timeoutCount: 1,
        executionTimeMs: 900, totalPoints: 126, earnedPoints: 84, warnings: ["w1"],
        jobStartedAt: started, runnerVersion: "shell-runner/1.0", timestamp: stamped)

    // MARK: - filtering(tiers:)

    @Test func filteringRecomputesEveryCountFromTheSurvivingOutcomes() {
        let filtered = Self.collection.filtering(tiers: ["public", "release"])
        #expect(filtered.outcomes.map(\.testName) == ["pub_pass", "pub_fail", "rel_error", "rel_timeout", "rel_pass"])
        #expect(filtered.totalTests == 5)
        #expect(filtered.passCount == 2)
        #expect(filtered.failCount == 1)
        #expect(filtered.errorCount == 1)
        #expect(filtered.timeoutCount == 1)
        #expect(filtered.totalPoints == 62)
        // 2 * 1 + 4 * 0.25 + 32 * 0.5 = 19
        #expect(filtered.earnedPoints == 19)
    }

    @Test func filteringKeepsTheRunMetadata() {
        let filtered = Self.collection.filtering(tiers: ["public"])
        #expect(filtered.submissionID == "sub-1")
        #expect(filtered.testSetupID == "setup-1")
        #expect(filtered.attemptNumber == 4)
        #expect(filtered.buildStatus == .passed)
        #expect(filtered.compilerOutput == "warning: unused")
        #expect(filtered.executionTimeMs == 900)
        #expect(filtered.warnings == ["w1"])
        #expect(filtered.jobStartedAt == Self.started)
        #expect(filtered.runnerVersion == "shell-runner/1.0")
        #expect(filtered.timestamp == Self.stamped)
        #expect(filtered.totalTests == 2)
        #expect(filtered.passCount == 1)
        #expect(filtered.failCount == 1)
        #expect(filtered.errorCount == 0)
        #expect(filtered.timeoutCount == 0)
        #expect(filtered.totalPoints == 6)
        #expect(filtered.earnedPoints == 3)
    }

    @Test func filteringToNoTierLeavesAnEmptyCollection() {
        let filtered = Self.collection.filtering(tiers: [])
        #expect(filtered.outcomes.isEmpty)
        #expect(filtered.totalTests == 0)
        #expect(filtered.totalPoints == 0)
        #expect(filtered.earnedPoints == 0)
    }

    // MARK: - replacingOutcomes(with:)

    @Test func replacingOutcomesKeepsEveryAggregate() {
        let visible = Array(Self.collection.outcomes.prefix(1))
        let replaced = Self.collection.replacingOutcomes(with: visible)
        #expect(replaced.outcomes.map(\.testName) == ["pub_pass"])
        #expect(replaced.submissionID == "sub-1")
        #expect(replaced.testSetupID == "setup-1")
        #expect(replaced.attemptNumber == 4)
        #expect(replaced.buildStatus == .passed)
        #expect(replaced.compilerOutput == "warning: unused")
        #expect(replaced.totalTests == 6)
        #expect(replaced.passCount == 3)
        #expect(replaced.failCount == 1)
        #expect(replaced.errorCount == 1)
        #expect(replaced.timeoutCount == 1)
        #expect(replaced.executionTimeMs == 900)
        #expect(replaced.totalPoints == 126)
        #expect(replaced.earnedPoints == 84)
        #expect(replaced.warnings == ["w1"])
        #expect(replaced.jobStartedAt == Self.started)
        #expect(replaced.runnerVersion == "shell-runner/1.0")
        #expect(replaced.timestamp == Self.stamped)
    }

    // MARK: - decodedCollection(from:)

    @Test func decodedCollectionReadsAnISO8601StoredCollection() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try #require(String(data: try encoder.encode(Self.collection), encoding: .utf8))
        let decoded = try #require(decodedCollection(from: json))
        #expect(decoded.outcomes.count == 6)
        #expect(decoded.timestamp == Self.stamped)
        #expect(decoded.earnedPoints == 84)
    }

    @Test func decodedCollectionIsNilForUnreadableJSON() {
        #expect(decodedCollection(from: "not json") == nil)
        #expect(decodedCollection(from: "") == nil)
    }

    // MARK: - gradePercent(from:)

    @Test func gradePercentDividesEarnedByTotal() {
        // 84 / 126 = 66.67 -> 67
        #expect(gradePercent(from: Self.collection) == 67)
        #expect(gradePercent(from: Self.collection.filtering(tiers: [])) == nil)
    }

    // MARK: - The deadline itself

    @Test func releaseOpensAtTheDeadlineInstant() {
        let deadline = Self.stamped
        #expect(releaseOutputVisible(isStaff: false, effectiveDueAt: deadline, now: deadline))
        #expect(
            visibleTiers(isStaff: false, effectiveDueAt: deadline, secretRevealed: false, now: deadline)
                == ["public", "release"])
    }
}
