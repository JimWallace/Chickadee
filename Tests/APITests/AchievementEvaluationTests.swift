// Tests/APITests/AchievementEvaluationTests.swift
//
// Phase 2 engine: the class-goal evaluation sweep computes one
// `APIAchievementResult` snapshot per (setup, achievement) from the per-student
// grades, over the enrolled roster, locking (and then freezing) at the deadline.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

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
                    id: id, name: "Class Goal", scope: .classWide,
                    conditions: [
                        AchievementCondition(
                            signal: .grade, comparator: .atLeast, value: threshold * 100)
                    ],
                    reward: AchievementReward(type: .points, label: "Class Goal Met", points: 5),
                    classFraction: classFraction)
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
                id: "ag_res_a", submissionID: "ag_sub_a"
            ).saveWithCollection(json: #"{"earnedPoints":4,"totalPoints":4}"#, on: app.db)
            _ = try await arInsertSubmission(
                id: "ag_sub_b", testSetupID: "ag_setup", userID: try b.requireID(), on: app)
            try await APIResult(
                id: "ag_res_b", submissionID: "ag_sub_b"
            ).saveWithCollection(json: #"{"earnedPoints":2,"totalPoints":4}"#, on: app.db)

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
                id: "frz_res_a", submissionID: "frz_sub_a"
            ).saveWithCollection(json: #"{"earnedPoints":4,"totalPoints":4}"#, on: app.db)

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
                id: "frz_res_b", submissionID: "frz_sub_b"
            ).saveWithCollection(json: #"{"earnedPoints":4,"totalPoints":4}"#, on: app.db)

            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)
            let after = try #require(
                try await APIAchievementResult.query(on: app.db)
                    .filter(\.$testSetupID == "frz_setup").first())
            #expect(after.studentsMeeting == 1, "A locked snapshot must not be recomputed")
        }
    }

    /// Audit A7 regression: the numerator must count only currently-enrolled
    /// per-course students — a 100% submission from a user with no enrollment
    /// (staff testing the assignment, or a student who dropped) used to
    /// inflate `studentsMeeting` while the denominator excluded them.
    @Test func sweepNumeratorExcludesUnenrolledSubmitters() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let setup = APITestSetup(
                id: "enr_setup",
                manifest: try makeClassGoalManifest(id: "goalE", threshold: 0.8, classFraction: 1.0),
                zipPath: app.testSetupsDirectory + "enr_setup.zip",
                courseID: courseID)
            try await setup.save(on: app.db)
            _ = try await arInsertAssignment(
                testSetupID: "enr_setup", title: "Enrollment Lab", isOpen: true, on: app)

            // Enrolled student at 100%.
            let enrolled = try await arInsertStudent(username: "enr_a", on: app)
            try await arEnrollStudentInTestCourse(enrolled, on: app)
            _ = try await arInsertSubmission(
                id: "enr_sub_a", testSetupID: "enr_setup", userID: try enrolled.requireID(), on: app)
            try await APIResult(
                id: "enr_res_a", submissionID: "enr_sub_a"
            ).saveWithCollection(json: #"{"earnedPoints":4,"totalPoints":4}"#, on: app.db)

            // Un-enrolled user, also at 100% — must NOT count.
            let outsider = try await arInsertStudent(username: "enr_x", on: app)
            _ = try await arInsertSubmission(
                id: "enr_sub_x", testSetupID: "enr_setup", userID: try outsider.requireID(), on: app)
            try await APIResult(
                id: "enr_res_x", submissionID: "enr_sub_x"
            ).saveWithCollection(json: #"{"earnedPoints":4,"totalPoints":4}"#, on: app.db)

            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)
            let snapshot = try #require(
                try await APIAchievementResult.query(on: app.db)
                    .filter(\.$testSetupID == "enr_setup").first())
            #expect(snapshot.studentsMeeting == 1, "un-enrolled submitters must not count")
        }
    }

    /// Audit A4 regression: a hand-authored class goal whose conditions the
    /// sweep cannot evaluate is skipped (no snapshot), not silently reduced to
    /// a grade-only goal.
    @Test func sweepSkipsUnsupportedGoalShapes() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let props = TestProperties(
                achievements: [
                    Achievement(
                        id: "goalU", name: "Unsupported", scope: .classWide,
                        conditions: [
                            AchievementCondition(signal: .attempts, comparator: .atMost, value: 3)
                        ],
                        reward: AchievementReward(type: .points, label: "Unsupported", points: 1),
                        classFraction: 0.5)
                ])
            let manifest = try #require(
                String(bytes: try JSONEncoder().encode(props), encoding: .utf8))
            let setup = APITestSetup(
                id: "uns_setup", manifest: manifest,
                zipPath: app.testSetupsDirectory + "uns_setup.zip",
                courseID: courseID)
            try await setup.save(on: app.db)
            _ = try await arInsertAssignment(
                testSetupID: "uns_setup", title: "Unsupported Lab", isOpen: true, on: app)

            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)
            let rows = try await APIAchievementResult.query(on: app.db)
                .filter(\.$testSetupID == "uns_setup").all()
            #expect(rows.isEmpty, "an unevaluable goal must be skipped, not mis-graded")
        }
    }
}
