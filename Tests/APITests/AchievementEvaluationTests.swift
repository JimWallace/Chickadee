// Tests/APITests/AchievementEvaluationTests.swift
//
// Phase 2 engine: the class-goal evaluation sweep computes one
// `APIAchievementResult` snapshot per (setup, achievement) from the per-student
// grades, over the enrolled roster, locking (and then freezing) at the deadline.

import Core
import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer

@Suite struct AchievementEvaluationTests {

    // MARK: - Pure progress math (no DB)

    @Test func classGoalProgressScalesAndClamps() {
        // Share of the class meeting the threshold, scaled by the target share.
        #expect(classGoalProgress(studentsMeeting: 0, denominator: 10, classFraction: 0.8) == 0)
        #expect(classGoalProgress(studentsMeeting: 4, denominator: 10, classFraction: 0.8) == 0.5)  // 0.4 / 0.8
        #expect(classGoalProgress(studentsMeeting: 8, denominator: 10, classFraction: 0.8) == 1.0)  // exactly met
        #expect(classGoalProgress(studentsMeeting: 10, denominator: 10, classFraction: 0.8) == 1.0)  // clamped
        #expect(classGoalProgress(studentsMeeting: 5, denominator: 0, classFraction: 0.8) == 0)  // empty roster
    }

    // MARK: - Full sweep (DB-backed)

    private func makeClassGoalManifest(
        id: String, threshold: Double, classFraction: Double
    ) throws -> String {
        let props = TestProperties(
            achievements: [
                Achievement(
                    id: id, name: "Class Goal", kind: .classGoal, scope: .classWide,
                    reward: AchievementReward(type: .points, label: "Class Goal Met", points: 5),
                    threshold: threshold, classFraction: classFraction)
            ])
        let data = try JSONEncoder().encode(props)
        return try #require(String(bytes: data, encoding: .utf8))
    }

    @Test func sweepComputesClassGoalSnapshot() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let setup = APITestSetup(
                id: "ag_setup",
                manifest: try makeClassGoalManifest(id: "goal1", threshold: 0.8, classFraction: 0.5),
                zipPath: app.testSetupsDirectory + "ag_setup.zip",
                courseID: courseID)
            try await setup.save(on: app.db)
            _ = try await arInsertAssignment(
                testSetupID: "ag_setup", title: "Goals Lab", isOpen: true, on: app)

            // Two enrolled students: A at 100% (meets 0.8), B at 50% (doesn't).
            let a = try await arInsertStudent(username: "ag_a", on: app)
            try await arEnrollStudentInTestCourse(a, on: app)
            let b = try await arInsertStudent(username: "ag_b", on: app)
            try await arEnrollStudentInTestCourse(b, on: app)
            _ = try await arInsertSubmission(
                id: "ag_sub_a", testSetupID: "ag_setup", userID: try a.requireID(), on: app)
            try await APIResult(
                id: "ag_res_a", submissionID: "ag_sub_a",
                collectionJSON: #"{"earnedPoints":4,"totalPoints":4}"#
            ).save(on: app.db)
            _ = try await arInsertSubmission(
                id: "ag_sub_b", testSetupID: "ag_setup", userID: try b.requireID(), on: app)
            try await APIResult(
                id: "ag_res_b", submissionID: "ag_sub_b",
                collectionJSON: #"{"earnedPoints":2,"totalPoints":4}"#
            ).save(on: app.db)

            let written = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)
            #expect(written >= 1)

            let snapshot = try #require(
                try await APIAchievementResult.query(on: app.db)
                    .filter(\.$testSetupID == "ag_setup").first())
            #expect(snapshot.achievementID == "goal1")
            #expect(snapshot.studentsMeeting == 1)
            #expect(snapshot.denominator == 2)
            #expect(snapshot.progress == 1.0)  // (1/2) reached / 0.5 target = 1.0
            #expect(snapshot.locked == false)  // no deadline → never locked
        }
    }

    @Test func frozenSnapshotIsNotRecomputed() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let setup = APITestSetup(
                id: "frz_setup",
                manifest: try makeClassGoalManifest(id: "goalF", threshold: 0.8, classFraction: 0.5),
                zipPath: app.testSetupsDirectory + "frz_setup.zip",
                courseID: courseID)
            try await setup.save(on: app.db)
            _ = try await arInsertAssignment(
                testSetupID: "frz_setup", title: "Frozen Lab", isOpen: true, on: app)

            let a = try await arInsertStudent(username: "frz_a", on: app)
            try await arEnrollStudentInTestCourse(a, on: app)
            _ = try await arInsertSubmission(
                id: "frz_sub_a", testSetupID: "frz_setup", userID: try a.requireID(), on: app)
            try await APIResult(
                id: "frz_res_a", submissionID: "frz_sub_a",
                collectionJSON: #"{"earnedPoints":4,"totalPoints":4}"#
            ).save(on: app.db)

            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)
            let row = try #require(
                try await APIAchievementResult.query(on: app.db)
                    .filter(\.$testSetupID == "frz_setup").first())
            #expect(row.studentsMeeting == 1)

            // Freeze it, then add another qualifying student and re-sweep.
            row.locked = true
            try await row.save(on: app.db)
            let b = try await arInsertStudent(username: "frz_b", on: app)
            try await arEnrollStudentInTestCourse(b, on: app)
            _ = try await arInsertSubmission(
                id: "frz_sub_b", testSetupID: "frz_setup", userID: try b.requireID(), on: app)
            try await APIResult(
                id: "frz_res_b", submissionID: "frz_sub_b",
                collectionJSON: #"{"earnedPoints":4,"totalPoints":4}"#
            ).save(on: app.db)

            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)
            let after = try #require(
                try await APIAchievementResult.query(on: app.db)
                    .filter(\.$testSetupID == "frz_setup").first())
            #expect(after.studentsMeeting == 1, "A locked snapshot must not be recomputed")
        }
    }
}
