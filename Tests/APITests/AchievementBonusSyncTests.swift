// Tests/APITests/AchievementBonusSyncTests.swift
//
// The class-goal bonus is scaled by LIVE class progress, but a BrightSpace push
// only ever happens when a new result, an override, or the manual "Push all"
// flags a row.  So a grade pushed while the class was still short of the goal
// carried whatever progress was in effect at that moment, and nothing ever
// corrected it: the class goal completing (or partly completing) moved every
// student's grade of record on Chickadee while LEARN kept the stale value.
//
// The freeze at the deadline is the moment the bonus becomes final.  These
// tests pin that transition re-queueing every student's grade for one push, and
// pin the three cases that must NOT re-queue.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct AchievementBonusSyncTests {

    // MARK: - Fixture

    private func classGoalManifest(id: String, points: Int) throws -> String {
        let props = TestProperties(
            testSuites: try JSONDecoder().decode(
                [TestSuiteEntry].self,
                from: Data(#"[{"tier":"public","script":"t.sh","points":4}]"#.utf8)),
            achievements: [
                Achievement(
                    id: id, name: "Class Goal", scope: .classWide,
                    conditions: [
                        AchievementCondition(signal: .grade, comparator: .atLeast, value: 100)
                    ],
                    reward: AchievementReward(type: .points, label: "Class Goal Met", points: points),
                    classFraction: 0.8)
            ])
        return try #require(String(bytes: try JSONEncoder().encode(props), encoding: .utf8))
    }

    /// One enrolled student with one already-synced result on a class-goal
    /// assignment.  `dueAt` in the past is what makes the sweep freeze the goal;
    /// `wiredToLEARN` controls whether the assignment has a grade item bound.
    @discardableResult
    private func seedClassGoalAssignment(
        prefix: String,
        dueAt: Date?,
        points: Int = 5,
        wiredToLEARN: Bool = true,
        on app: Application
    ) async throws -> APIResult {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        if wiredToLEARN, let course = try await APICourse.find(courseID, on: app.db) {
            course.brightspaceOrgUnitID = "1265792"
            try await course.save(on: app.db)
        }

        let setup = APITestSetup(
            id: "\(prefix)_setup",
            manifest: try classGoalManifest(id: "\(prefix)_goal", points: points),
            zipPath: app.testSetupsDirectory + "\(prefix)_setup.zip",
            courseID: courseID)
        try await setup.save(on: app.db)

        let assignment = try await arInsertAssignment(
            testSetupID: "\(prefix)_setup", title: "\(prefix) Lab", isOpen: true, dueAt: dueAt,
            on: app)
        if wiredToLEARN {
            assignment.brightspaceGradeObjectID = "9001"
            try await assignment.save(on: app.db)
        }

        let student = try await arInsertStudent(username: "\(prefix)_student", on: app)
        try await arEnrollStudentInTestCourse(student, on: app)
        _ = try await arInsertSubmission(
            id: "\(prefix)_sub", testSetupID: "\(prefix)_setup", userID: try student.requireID(),
            on: app)

        let result = APIResult(id: "\(prefix)_res", submissionID: "\(prefix)_sub")
        try await result.saveWithCollection(
            json: #"{"earnedPoints":4,"totalPoints":4}"#, on: app.db)
        // Already pushed to LEARN, at whatever bonus was live back then.
        result.brightspaceSyncPending = false
        result.brightspacePendingSince = nil
        result.brightspaceSyncedAt = Date()
        try await result.save(on: app.db)
        return result
    }

    private func reloadResult(_ id: String, on app: Application) async throws -> APIResult {
        try #require(try await APIResult.find(id, on: app.db))
    }

    // MARK: - The freeze re-pushes

    @Test func freezingAPointsGoalRequeuesEveryGradePush() async throws {
        try await withAssignmentRoutesApp { app in
            try await seedClassGoalAssignment(
                prefix: "bfz", dueAt: Date().addingTimeInterval(-3600), on: app)

            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)

            let snapshot = try #require(
                try await APIAchievementResult.query(on: app.db)
                    .filter(\.$testSetupID == "bfz_setup").first())
            #expect(snapshot.locked, "a past deadline freezes the goal")

            let result = try await reloadResult("bfz_res", on: app)
            #expect(
                result.brightspaceSyncPending == true,
                "the frozen bonus must be pushed to LEARN, not left at the progress in effect when this student's own submission was graded"
            )
            // `Date.distantPast` is the "retry immediately" sentinel — the next
            // sweep must not wait out the debounce window.
            #expect(result.brightspacePendingSince == Date.distantPast)
            #expect(result.brightspaceSyncError == nil)
        }
    }

    /// The sweep never re-opens a locked snapshot, so the re-push fires exactly
    /// once in an assignment's life — not on every 5-minute sweep forever.
    @Test func theFreezeRequeuesOnlyOnce() async throws {
        try await withAssignmentRoutesApp { app in
            try await seedClassGoalAssignment(
                prefix: "bonce", dueAt: Date().addingTimeInterval(-3600), on: app)

            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)
            #expect(try await reloadResult("bonce_res", on: app).brightspaceSyncPending == true)

            // Simulate the BrightSpace sweep having pushed it.
            let pushed = try await reloadResult("bonce_res", on: app)
            pushed.brightspaceSyncPending = false
            pushed.brightspacePendingSince = nil
            pushed.brightspaceSyncedAt = Date()
            try await pushed.save(on: app.db)

            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)
            #expect(
                try await reloadResult("bonce_res", on: app).brightspaceSyncPending != true,
                "a locked goal must not re-queue the class on every later sweep")
        }
    }

    // MARK: - What must NOT re-queue

    @Test func aLiveGoalDoesNotRequeue() async throws {
        try await withAssignmentRoutesApp { app in
            // No deadline → never locked → the bonus is still moving.
            try await seedClassGoalAssignment(prefix: "blive", dueAt: nil, on: app)

            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)

            let snapshot = try #require(
                try await APIAchievementResult.query(on: app.db)
                    .filter(\.$testSetupID == "blive_setup").first())
            #expect(snapshot.locked == false)
            #expect(
                try await reloadResult("blive_res", on: app).brightspaceSyncPending != true,
                "re-pushing on every progress change would push the whole class every sweep")
        }
    }

    @Test func anAssignmentWithNoGradeItemDoesNotRequeue() async throws {
        try await withAssignmentRoutesApp { app in
            try await seedClassGoalAssignment(
                prefix: "bnol", dueAt: Date().addingTimeInterval(-3600), wiredToLEARN: false,
                on: app)

            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)

            #expect(try await reloadResult("bnol_res", on: app).brightspaceSyncPending != true)
        }
    }

    @Test func aGoalAwardingNoPointsDoesNotRequeue() async throws {
        try await withAssignmentRoutesApp { app in
            try await seedClassGoalAssignment(
                prefix: "bzero", dueAt: Date().addingTimeInterval(-3600), points: 0, on: app)

            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)

            #expect(
                try await reloadResult("bzero_res", on: app).brightspaceSyncPending != true,
                "a goal that moves no grade is no reason to re-push the class")
        }
    }

    @Test func anExcludedAssignmentDoesNotRequeue() async throws {
        try await withAssignmentRoutesApp { app in
            try await seedClassGoalAssignment(
                prefix: "bexc", dueAt: Date().addingTimeInterval(-3600), on: app)
            let assignment = try #require(
                try await APIAssignment.query(on: app.db)
                    .filter(\.$testSetupID == "bexc_setup").first())
            assignment.brightspaceSyncExcluded = true
            try await assignment.save(on: app.db)

            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)

            #expect(
                try await reloadResult("bexc_res", on: app).brightspaceSyncPending != true,
                "'Do not sync' is a deliberate choice the freeze must not override")
        }
    }
}
