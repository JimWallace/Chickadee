// Tests/CoreTests/AchievementTestPassMatchingTests.swift
//
// Regression tests for the 2026-07 audit's A1/A14 findings: a `testPass`
// condition authored per the documented contract (the script filename) must
// resolve against outcomes as runners actually stamp them — the display name
// when the suite entry has one, else the extension-stripped filename stem
// (`runnerOutcomeTestName`).  The old matcher compared the ref to
// `outcome.testName` by raw equality only, so a filename ref never fired.

import Foundation
import Testing

@testable import Core

@Suite struct AchievementTestPassMatchingTests {

    private func passOutcome(named name: String) -> TestOutcome {
        TestOutcome(
            testName: name, testClass: nil, tier: .pub, status: .pass,
            shortResult: "ok", longResult: nil, executionTimeMs: 1, memoryUsageBytes: nil,
            attemptNumber: 1, isFirstPassSuccess: true)
    }

    private func testPassBadge(
        ref: String, extraConditions: [AchievementCondition] = []
    )
        -> Achievement
    {
        Achievement(
            id: "tp", name: "TP", scope: .individual,
            conditions: [
                AchievementCondition(
                    signal: .testPass, comparator: .atLeast, value: 1,
                    target: AchievementTarget(kind: .testPass, ref: ref))
            ] + extraConditions,
            reward: AchievementReward(type: .badge, label: "TP"))
    }

    /// Suite mirroring a real lab: one display-named script, one bare script.
    private var props: TestProperties {
        TestProperties(
            testSuites: [
                TestSuiteEntry(
                    tier: .pub, script: "publictest_bigo_linear.py", name: "Big-O: linear search"),
                TestSuiteEntry(tier: .pub, script: "test_plain.sh"),
            ])
    }

    @Test func filenameRefMatchesDisplayNamedOutcomeViaAliases() {
        // The runner stamps the display name; the ref is the filename.
        let signals = AchievementSignals(
            gradePercent: 0,
            outcomes: [passOutcome(named: "Big-O: linear search")],
            testNameAliases: props.testNameAliases())
        #expect(testPassBadge(ref: "publictest_bigo_linear.py").isSatisfied(by: signals))
        // The display name itself is also a legal ref.
        #expect(testPassBadge(ref: "Big-O: linear search").isSatisfied(by: signals))
        // An unrelated ref still doesn't fire.
        #expect(!testPassBadge(ref: "test_plain.sh").isSatisfied(by: signals))
    }

    @Test func filenameRefMatchesStemOutcomeWithoutAliases() {
        // A display-name-less script's outcome carries the filename stem; the
        // stem-of-ref fallback resolves it even at alias-less call sites.
        let signals = AchievementSignals(
            gradePercent: 0, outcomes: [passOutcome(named: "test_plain")])
        #expect(testPassBadge(ref: "test_plain.sh").isSatisfied(by: signals))
        #expect(testPassBadge(ref: "test_plain").isSatisfied(by: signals))
        #expect(!testPassBadge(ref: "test_other.sh").isSatisfied(by: signals))
    }

    @Test func failingOutcomeNeverMatches() {
        let fail = TestOutcome(
            testName: "test_plain", testClass: nil, tier: .pub, status: .fail,
            shortResult: "no", longResult: nil, executionTimeMs: 1, memoryUsageBytes: nil,
            attemptNumber: 1, isFirstPassSuccess: false)
        let signals = AchievementSignals(gradePercent: 100, outcomes: [fail])
        #expect(!testPassBadge(ref: "test_plain.sh").isSatisfied(by: signals))
    }

    @Test func mixedDynamicAndTestPassBadgeIsSatisfiable() {
        // Audit A14: a badge mixing a dynamic signal (attempts) with testPass
        // was unearnable because no evaluation site carried both signal kinds.
        let badge = testPassBadge(
            ref: "publictest_bigo_linear.py",
            extraConditions: [
                AchievementCondition(signal: .attempts, comparator: .atMost, value: 1)
            ])
        let signals = AchievementSignals(
            gradePercent: 100,
            attemptNumber: 1,
            outcomes: [passOutcome(named: "Big-O: linear search")],
            testNameAliases: props.testNameAliases())
        #expect(badge.isSatisfied(by: signals))

        let secondAttempt = AchievementSignals(
            gradePercent: 100,
            attemptNumber: 2,
            outcomes: [passOutcome(named: "Big-O: linear search")],
            testNameAliases: props.testNameAliases())
        #expect(!badge.isSatisfied(by: secondAttempt))
    }

    @Test func aliasMapCoversGeneratedStyleCaseLabels() {
        // Generated pattern-family entries carry the case label as their
        // display name — both the generated filename and the label must
        // resolve.
        let familyProps = TestProperties(
            testSuites: [
                TestSuiteEntry(
                    tier: .pub, script: "publictest_maximum_04.py",
                    name: "largest comes first", generatedBy: "maximum")
            ])
        let signals = AchievementSignals(
            gradePercent: 0,
            outcomes: [passOutcome(named: "largest comes first")],
            testNameAliases: familyProps.testNameAliases())
        #expect(testPassBadge(ref: "publictest_maximum_04.py").isSatisfied(by: signals))
        #expect(testPassBadge(ref: "largest comes first").isSatisfied(by: signals))
    }
}
