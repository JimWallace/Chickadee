// Tests/APITests/BuiltInAwardTogglesTests.swift
//
// The disabled-built-in honoring (toggles are now managed via the unified
// Achievements table; the /built-in-awards endpoint was retired): forSubmission
// + forClassAchievement + awardClassBadgesFor100Percent skip a disabled award,
// and a suite rebuild preserves both the disabled set and authored achievements.

import Core
import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer

@Suite struct BuiltInAwardTogglesTests {

    @Test func forSubmissionAndClassRecordsHonorDisabled() {
        let ctx = BadgeContext(
            attemptNumber: 1, gradePercent: 100, executionTimeMs: 1_000, priorGradePercent: nil)
        // First-try perfect + fast → Ace + Swift.
        #expect(Set(AchievementBadge.forSubmission(ctx).map(\.id)) == ["first_try_perfect", "speed_demon"])
        // Disabling Ace leaves only Swift.
        #expect(
            AchievementBadge.forSubmission(ctx, disabled: ["first_try_perfect"]).map(\.id)
                == ["speed_demon"])
        // Class records honor the disabled set.
        #expect(AchievementBadge.forClassAchievement("trailblazer") != nil)
        #expect(AchievementBadge.forClassAchievement("trailblazer", disabled: ["trailblazer"]) == nil)
    }

    @Test func suiteRebuildPreservesAchievementsAndToggles() throws {
        // Regression: makeWorkerManifestJSON builds a fresh dict, so before the
        // fix a suite edit wiped authored achievements (and would wipe toggles).
        let goal = Achievement(
            id: "g1", name: "Goal", kind: .classGoal, scope: .classWide,
            reward: AchievementReward(type: .points, label: "Goal", points: 5),
            threshold: 0.8, classFraction: 0.8)
        let json = try makeWorkerManifestJSON(
            testSuites: [], includeMakefile: false,
            achievements: [goal], disabledBuiltInAwardIDs: ["trailblazer", "speed_champion"])
        let props = try JSONDecoder().decode(TestProperties.self, from: Data(json.utf8))
        #expect(props.achievements.map(\.id) == ["g1"])
        #expect(Set(props.disabledBuiltInAwardIDs) == ["trailblazer", "speed_champion"])
    }

    @Test func awardClassBadgesSkipsDisabledRecords() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let setup = APITestSetup(
                id: "ba_award_setup", manifest: #"{"schemaVersion":1}"#,
                zipPath: app.testSetupsDirectory + "ba_award_setup.zip", courseID: courseID)
            try await setup.save(on: app.db)
            let student = try await arInsertStudent(username: "ba_student", on: app)
            let uid = try student.requireID()
            _ = try await arInsertSubmission(
                id: "ba_award_sub", testSetupID: "ba_award_setup", userID: uid, on: app)

            try await awardClassBadgesFor100Percent(
                testSetupID: "ba_award_setup", userID: uid, submissionID: "ba_award_sub",
                executionTimeMs: 100, attemptNumber: 1,
                disabled: ["trailblazer", "speed_champion", "minimalist"], on: app.db)

            let rows = try await APIClassAchievement.query(on: app.db)
                .filter(\.$testSetupID == "ba_award_setup")
                .all()
            #expect(rows.isEmpty, "Every class record disabled → none awarded")
        }
    }
}
