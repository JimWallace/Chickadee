// Tests/APITests/AchievementBadgeTests.swift
//
// Per-student evaluation of individual badges (thresholdBadge / testBadge):
// earnedIndividualBadges awards a badge from the student's own result, including
// one keyed to a secret test.  (Authoring is now via the unified /achievements
// endpoint + the Achievements table; the legacy /badges endpoint was retired.)

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct AchievementBadgeTests {

    @Test func earnedIndividualBadgesEvaluatesThresholdAndTest() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let props = TestProperties(achievements: [
                Achievement(
                    id: "b_thr", name: "Sharpshooter", scope: .individual,
                    conditions: [
                        AchievementCondition(signal: .grade, comparator: .atLeast, value: 80)
                    ],
                    reward: AchievementReward(type: .badge, label: "Sharpshooter", icon: "🌟")),
                Achievement(
                    id: "b_test", name: "Recursion Master", scope: .individual,
                    conditions: [
                        AchievementCondition(
                            signal: .testPass, comparator: .atLeast, value: 1,
                            target: AchievementTarget(kind: .testPass, ref: "secrettest_rec.py"))
                    ],
                    reward: AchievementReward(type: .badge, label: "Recursion Master", icon: "🌀")),
            ])
            let manifest = try #require(String(bytes: try JSONEncoder().encode(props), encoding: .utf8))
            let setup = APITestSetup(
                id: "badge_eval_setup", manifest: manifest,
                zipPath: app.testSetupsDirectory + "badge_eval_setup.zip", courseID: courseID)
            try await setup.save(on: app.db)

            let passing = TestOutcome(
                testName: "secrettest_rec.py", testClass: nil, tier: .secret, status: .pass,
                shortResult: "passed", longResult: nil, executionTimeMs: 1, memoryUsageBytes: nil,
                attemptNumber: 1, isFirstPassSuccess: true)

            // 90% + the secret test passing → both badges (the secret test is
            // readable here even though the student never sees it).
            let both = try await earnedIndividualBadges(
                testSetupID: "badge_eval_setup", gradePercent: 90, outcomes: [passing], on: app.db)
            #expect(Set(both.map(\.label)) == ["🌟 Sharpshooter", "🌀 Recursion Master"])

            // 70% + the test failing → neither.
            let failing = TestOutcome(
                testName: "secrettest_rec.py", testClass: nil, tier: .secret, status: .fail,
                shortResult: "failed", longResult: nil, executionTimeMs: 1, memoryUsageBytes: nil,
                attemptNumber: 1, isFirstPassSuccess: false)
            let none = try await earnedIndividualBadges(
                testSetupID: "badge_eval_setup", gradePercent: 70, outcomes: [failing], on: app.db)
            #expect(none.isEmpty)
        }
    }
}
