// Tests/APITests/AchievementManifestSourcingTests.swift
//
// Unification A2: forSubmission sources per-submission badges from the manifest
// when provided (and honors the parameterized thresholds), else falls back to
// the registry.

import Core
import Testing

@testable import APIServer

@Suite struct AchievementManifestSourcingTests {

    @Test func forSubmissionSourcesFromManifestAndRespectsThresholds() {
        // First-try 100% in 1500 ms.
        let ctx = BadgeContext(
            attemptNumber: 1, gradePercent: 100, executionTimeMs: 1_500, priorGradePercent: nil)

        // No list → registry fallback: Ace (first-try) + Swift (1500 < 2000 default).
        #expect(
            Set(AchievementBadge.forSubmission(ctx).map(\.id)) == ["first_try_perfect", "speed_demon"])

        // A manifest "speed" badge with a tighter 500 ms cutoff is NOT earned at 1500 ms,
        // and the registry defaults no longer apply (manifest is authoritative).
        let tight = [
            Achievement(
                id: "lightning", name: "Lightning", kind: .speedRun, scope: .individual,
                reward: AchievementReward(type: .badge, label: "Lightning"),
                threshold: 1.0, timeThresholdMs: 500)
        ]
        #expect(AchievementBadge.forSubmission(ctx, achievements: tight).isEmpty)

        // A looser 3000 ms cutoff IS earned — and only the manifest badge shows.
        let loose = [
            Achievement(
                id: "cruise", name: "Cruise", kind: .speedRun, scope: .individual,
                reward: AchievementReward(type: .badge, label: "Cruise"),
                threshold: 1.0, timeThresholdMs: 3_000)
        ]
        #expect(AchievementBadge.forSubmission(ctx, achievements: loose).map(\.id) == ["cruise"])
    }

    @Test func forSubmissionCustomAttemptAndJumpThresholds() {
        // A "persistence" badge tuned to ≥ 3 attempts fires on attempt 3.
        let persistent = [
            Achievement(
                id: "grit", name: "Grit", kind: .persistence, scope: .individual,
                reward: AchievementReward(type: .badge, label: "Grit"),
                threshold: 1.0, attemptThreshold: 3)
        ]
        let onThird = BadgeContext(
            attemptNumber: 3, gradePercent: 100, executionTimeMs: 9_000, priorGradePercent: 100)
        #expect(AchievementBadge.forSubmission(onThird, achievements: persistent).map(\.id) == ["grit"])
        let onSecond = BadgeContext(
            attemptNumber: 2, gradePercent: 100, executionTimeMs: 9_000, priorGradePercent: 100)
        #expect(AchievementBadge.forSubmission(onSecond, achievements: persistent).isEmpty)
    }
}
