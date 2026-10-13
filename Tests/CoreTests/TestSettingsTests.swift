// Tests/CoreTests/TestSettingsTests.swift
//
// `TestSettings` is a view over the per-test fields that four manifest types
// declare.  These tests pin each view, the case-over-family resolution, and
// that the entry setter writes the stored fields.

import Foundation
import Testing

@testable import Core

@Suite struct TestSettingsTests {

    private let defaults = PatternDefaults(
        tier: .release, points: 3, hint: "family hint",
        timeLimitSeconds: 20, failureDetail: .actualOnly)

    @Test func familyDefaultsView() {
        #expect(
            defaults.settings
                == TestSettings(
                    tier: .release, points: 3, hint: "family hint",
                    timeLimitSeconds: 20, failureDetail: .actualOnly))
    }

    @Test func caseWithoutOverridesGetsFamilyDefaults() {
        let plain = PatternCase(key: "a", label: "a", args: [], expected: .int(1))
        #expect(plain.resolvedSettings(defaults: defaults) == defaults.settings)
    }

    @Test func caseOverridesWinFieldByField() {
        let overriding = PatternCase(
            key: "a", label: "a", args: [], expected: .int(1),
            hint: "case hint", tier: .secret, points: 5,
            timeLimitSeconds: 4, failureDetail: .verdictOnly)
        #expect(
            overriding.resolvedSettings(defaults: defaults)
                == TestSettings(
                    tier: .secret, points: 5, hint: "case hint",
                    timeLimitSeconds: 4, failureDetail: .verdictOnly))
    }

    /// An empty case hint is not an override: `resolvedHint` falls back.
    @Test func emptyCaseHintFallsBackToFamilyHint() {
        let blank = PatternCase(key: "a", label: "a", args: [], expected: .int(1), hint: "")
        #expect(blank.resolvedSettings(defaults: defaults).hint == "family hint")
    }

    @Test func notebookCheckView() {
        let check = NotebookCheck(
            id: "c", kind: .figureCount, tier: .release, points: 2,
            hint: "h", timeLimitSeconds: 7, failureDetail: .actualOnly, minFigures: 1)
        #expect(
            check.settings
                == TestSettings(
                    tier: .release, points: 2, hint: "h",
                    timeLimitSeconds: 7, failureDetail: .actualOnly))
    }

    @Test func suiteEntrySetterWritesStoredFields() {
        var entry = TestSuiteEntry(tier: .pub, script: "test_a.sh")
        entry.settings = TestSettings(
            tier: .secret, points: 0, hint: "h", timeLimitSeconds: 9, failureDetail: .verdictOnly)
        #expect(entry.tier == .secret)
        #expect(entry.points == 0)
        #expect(entry.hint == "h")
        #expect(entry.timeLimitSeconds == 9)
        #expect(entry.failureDetail == .verdictOnly)
        #expect(
            entry.settings
                == TestSettings(
                    tier: .secret, points: 0, hint: "h", timeLimitSeconds: 9, failureDetail: .verdictOnly))
    }
}
