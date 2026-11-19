// Tests/APITests/Gamification/ClassGoalArchivedCourseTests.swift
//
// The class-goal sweep skips archived courses: their goals are history, and
// the sweep runs on a timer forever. A goal in an active course still gets
// its snapshot; the same goal in an archived course gets none, and a snapshot
// it already had is left as it was.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5)))
struct ClassGoalArchivedCourseTests {

    private func classGoalManifest(id: String) throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "t.sh")],
            language: nil,
            achievements: [
                Achievement(
                    id: id, name: "Class Goal", scope: .classWide,
                    conditions: [AchievementCondition(signal: .grade, comparator: .atLeast, value: 100)],
                    reward: AchievementReward(type: .points, label: "Class Goal Met", points: 5),
                    classFraction: 0.8)
            ])
        return try #require(String(bytes: try JSONEncoder().encode(props), encoding: .utf8))
    }

    /// A course with one class-goal assignment, due in a day, and one student
    /// who has full credit on it.
    private func seed(code: String, archived: Bool, on app: Application) async throws -> String {
        let course = try await makeTestCourse(on: app, code: code, archived: archived)
        let courseID = try course.requireID()
        let setupID = "setup_\(code.lowercased())"
        try await makeTestSetup(
            on: app, id: setupID, courseID: courseID, manifest: try classGoalManifest(id: "\(code)_goal"))
        try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: courseID, dueAt: Date().addingTimeInterval(86_400))
        // The sweep counts goals over the class, so the class has a student
        // with a full-credit result.
        let student = try await makeTestStudent(on: app, username: "\(code.lowercased())_student")
        try await makeTestEnrollment(on: app, userID: try student.requireID(), courseID: courseID)
        let submissionID = "sub_\(code.lowercased())"
        try await makeTestSubmission(on: app, id: submissionID, setupID: setupID, userID: try student.requireID())
        let result = APIResult(id: "res_\(code.lowercased())", submissionID: submissionID)
        try await result.saveWithCollection(json: #"{"earnedPoints":1,"totalPoints":1}"#, on: app.db)
        return setupID
    }

    private func snapshots(_ setupID: String, on app: Application) async throws -> [APIAchievementResult] {
        try await APIAchievementResult.query(on: app.db).filter(\.$testSetupID == setupID).all()
    }

    @Test func theSweepSkipsAnArchivedCourse() async throws {
        try await withTestApp(prefix: "chickadee-goal-archived") { app in
            let active = try await seed(code: "GOALACT", archived: false, on: app)
            let archived = try await seed(code: "GOALARC", archived: true, on: app)

            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)

            #expect(try await snapshots(active, on: app).count == 1)
            #expect(try await snapshots(archived, on: app).isEmpty)
        }
    }

    @Test func aSnapshotFromBeforeTheArchiveIsLeftAsItWas() async throws {
        try await withTestApp(prefix: "chickadee-goal-archived-kept") { app in
            let setupID = try await seed(code: "GOALKEPT", archived: false, on: app)
            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)
            let before = try #require(try await snapshots(setupID, on: app).first)

            let course = try #require(try await APICourse.query(on: app.db).filter(\.$code == "GOALKEPT").first())
            course.isArchived = true
            try await course.save(on: app.db)
            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)

            let after = try #require(try await snapshots(setupID, on: app).first)
            #expect(after.evaluatedAt == before.evaluatedAt)
            #expect(after.locked == before.locked)
        }
    }
}
