// Tests/CoreTests/AchievementLegacyKindTests.swift
//
// The legacy `kind` projection in `Achievement.init(from:)`, for the five
// kinds that `AchievementTests` does not decode: `thresholdBadge`,
// `testBadge`, `persistence`, `comeback` and `speedRun`. Each case pins the
// conditions a manifest authored before the composable redesign must
// evaluate as, including the default thresholds the old editor applied
// when a flat field was absent.

import Foundation
import Testing

@testable import Core

@Suite struct AchievementLegacyKindTests {

    private func decode(_ json: String) throws -> Achievement {
        try JSONDecoder().decode(Achievement.self, from: Data(json.utf8))
    }

    @Test func thresholdBadgeProjectsToOneGradeCondition() throws {
        let a = try decode(
            #"""
            {"id":"b","name":"Pass","kind":"thresholdBadge","scope":"individual",
             "reward":{"type":"badge","label":"Pass"},"threshold":0.5}
            """#)
        #expect(a.scope == .individual)
        #expect(a.match == .all)
        #expect(a.recordDimension == nil)
        #expect(a.conditions == [AchievementCondition(signal: .grade, comparator: .atLeast, value: 50)])
    }

    @Test func aMissingThresholdDefaultsToFullMarks() throws {
        let a = try decode(
            #"""
            {"id":"b","name":"Pass","kind":"thresholdBadge","scope":"individual",
             "reward":{"type":"badge","label":"Pass"}}
            """#)
        #expect(a.conditions == [AchievementCondition(signal: .grade, comparator: .atLeast, value: 100)])
    }

    @Test func testBadgeKeepsTheTargetTestReference() throws {
        let a = try decode(
            #"""
            {"id":"t","name":"Edge","kind":"testBadge","scope":"individual",
             "reward":{"type":"badge","label":"Edge"},
             "target":{"kind":"testPass","ref":"secrettest_edge.py"}}
            """#)
        #expect(a.scope == .individual)
        #expect(
            a.conditions == [
                AchievementCondition(
                    signal: .testPass, comparator: .atLeast, value: 1,
                    target: AchievementTarget(kind: .testPass, ref: "secrettest_edge.py"))
            ])
    }

    @Test func testBadgeWithoutATargetHasANilReference() throws {
        let a = try decode(
            #"""
            {"id":"t","name":"Edge","kind":"testBadge","scope":"individual",
             "reward":{"type":"badge","label":"Edge"}}
            """#)
        #expect(a.conditions.count == 1)
        #expect(a.conditions.first?.target == AchievementTarget(kind: .testPass, ref: nil))
    }

    @Test func persistenceUsesTheAuthoredAttemptCount() throws {
        let a = try decode(
            #"""
            {"id":"p","name":"Grit","kind":"persistence","scope":"individual",
             "reward":{"type":"badge","label":"Grit"},"threshold":0.9,"attemptThreshold":8}
            """#)
        #expect(
            a.conditions == [
                AchievementCondition(signal: .grade, comparator: .atLeast, value: 90),
                AchievementCondition(signal: .attempts, comparator: .atLeast, value: 8),
            ])
    }

    @Test func persistenceDefaultsToFiveAttempts() throws {
        let a = try decode(
            #"""
            {"id":"p","name":"Grit","kind":"persistence","scope":"individual",
             "reward":{"type":"badge","label":"Grit"}}
            """#)
        #expect(
            a.conditions == [
                AchievementCondition(signal: .grade, comparator: .atLeast, value: 100),
                AchievementCondition(signal: .attempts, comparator: .atLeast, value: 5),
            ])
    }

    @Test func comebackReadsTheJumpThresholdAndNoGrade() throws {
        let a = try decode(
            #"""
            {"id":"c","name":"Back","kind":"comeback","scope":"individual",
             "reward":{"type":"badge","label":"Back"},"threshold":0.9,"jumpThresholdPercent":30}
            """#)
        #expect(
            a.conditions == [
                AchievementCondition(signal: .gradeJumpPercent, comparator: .atLeast, value: 30)
            ])
    }

    @Test func comebackDefaultsToAFiftyPointJump() throws {
        let a = try decode(
            #"""
            {"id":"c","name":"Back","kind":"comeback","scope":"individual",
             "reward":{"type":"badge","label":"Back"}}
            """#)
        #expect(
            a.conditions == [
                AchievementCondition(signal: .gradeJumpPercent, comparator: .atLeast, value: 50)
            ])
    }

    @Test func speedRunPairsAGradeWithAnExecutionTimeCeiling() throws {
        let a = try decode(
            #"""
            {"id":"s","name":"Quick","kind":"speedRun","scope":"individual",
             "reward":{"type":"badge","label":"Quick"},"threshold":1.0,"timeThresholdMs":750}
            """#)
        #expect(
            a.conditions == [
                AchievementCondition(signal: .grade, comparator: .atLeast, value: 100),
                AchievementCondition(signal: .executionTimeMs, comparator: .atMost, value: 750),
            ])
    }

    @Test func speedRunDefaultsToTwoSeconds() throws {
        let a = try decode(
            #"""
            {"id":"s","name":"Quick","kind":"speedRun","scope":"individual",
             "reward":{"type":"badge","label":"Quick"}}
            """#)
        #expect(a.conditions.last == AchievementCondition(signal: .executionTimeMs, comparator: .atMost, value: 2000))
    }

    /// An unknown or absent `kind` falls through to the record projection, so
    /// a manifest with no conditions and no kind decodes rather than throws.
    @Test func anUnknownKindProjectsToAnEmptyRecord() throws {
        let a = try decode(
            #"""
            {"id":"x","name":"Mystery","kind":"notAKind","scope":"individual",
             "reward":{"type":"title","label":"Mystery"},"recordDimension":"fastest"}
            """#)
        #expect(a.scope == .record)
        #expect(a.conditions.isEmpty)
        #expect(a.recordDimension == .fastest)
    }

    /// Re-saving migrates forward: the encoded form carries `conditions` and
    /// no legacy `kind`, and it decodes back to the same value.
    @Test func reEncodingALegacyKindWritesTheNewShape() throws {
        let legacy = try decode(
            #"""
            {"id":"s","name":"Quick","kind":"speedRun","scope":"individual",
             "reward":{"type":"badge","label":"Quick"},"timeThresholdMs":900}
            """#)
        let data = try JSONEncoder().encode(legacy)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["kind"] == nil)
        #expect(object["conditions"] != nil)
        #expect(try JSONDecoder().decode(Achievement.self, from: data) == legacy)
    }
}
