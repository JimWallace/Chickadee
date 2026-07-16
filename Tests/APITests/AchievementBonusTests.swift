// Tests/APITests/AchievementBonusTests.swift
//
// Phase 3b: the class-goal grade bonus — extra credit, capped at 100% — applied
// at the grade-of-record sites. The pure cap is unit-tested; the grades CSV
// (an official export) is exercised end-to-end. The submission page and the
// BrightSpace push apply the same `classGoalBonusPoints` + `earnedWithClassGoalBonus`.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct AchievementBonusTests {

    @Test func earnedWithClassGoalBonusCapsAtTotal() {
        #expect(earnedWithClassGoalBonus(earned: 18, total: 20, bonus: 5) == 20)  // capped at 100%
        #expect(earnedWithClassGoalBonus(earned: 10, total: 20, bonus: 5) == 15)  // under the cap
        #expect(earnedWithClassGoalBonus(earned: 18, total: 20, bonus: 0) == 18)  // no bonus
        #expect(earnedWithClassGoalBonus(earned: 18, total: 0, bonus: 5) == 18)  // no total → untouched
    }

    @Test func gradesCSVIncludesCappedClassGoalBonus() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)

            // Suite worth 20 points + a class goal awarding +5.
            let testSuites = try JSONDecoder().decode(
                [TestSuiteEntry].self,
                from: Data(#"[{"tier":"public","script":"t.sh","points":20}]"#.utf8))
            let props = TestProperties(
                testSuites: testSuites,
                achievements: [
                    Achievement(
                        id: "g_csv", name: "Mastery", scope: .classWide,
                        conditions: [
                            AchievementCondition(signal: .grade, comparator: .atLeast, value: 80)
                        ],
                        reward: AchievementReward(type: .points, label: "Mastery", points: 5),
                        classFraction: 0.8)
                ])
            let manifest = try #require(String(bytes: try JSONEncoder().encode(props), encoding: .utf8))
            let setup = APITestSetup(
                id: "csv_bonus_setup", manifest: manifest,
                zipPath: app.testSetupsDirectory + "csv_bonus_setup.zip", courseID: courseID)
            try await setup.save(on: app.db)
            _ = try await arInsertAssignment(
                testSetupID: "csv_bonus_setup", title: "Bonus CSV", isOpen: true, on: app)

            let student = try await arInsertStudent(username: "csv_bonus_student", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            _ = try await arInsertSubmission(
                id: "csv_bonus_sub", testSetupID: "csv_bonus_setup",
                userID: try student.requireID(), on: app)
            // Earned 18/20; the class reached the goal (progress 1.0) → +5 bonus.
            try await APIResult(
                id: "csv_bonus_res", submissionID: "csv_bonus_sub"
            ).saveWithCollection(
                json: #"{"earnedPoints":18,"totalPoints":20,"passCount":18,"totalTests":20}"#, on: app.db)
            try await APIAchievementResult(
                testSetupID: "csv_bonus_setup", achievementID: "g_csv",
                studentsMeeting: 8, denominator: 10, progress: 1.0, locked: false,
                evaluatedAt: Date()
            ).save(on: app.db)

            try await app.asyncTest(
                .GET, "/instructor/grades.csv",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(body.contains("20.0"), "18/20 + 5 bonus capped at 20 must export as 20.0")
                    #expect(!body.contains("18.0"), "Raw 18 must be replaced by the bonused 20")
                })
        }
    }
}
