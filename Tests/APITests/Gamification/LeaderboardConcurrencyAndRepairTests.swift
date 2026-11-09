// Tests/APITests/Gamification/LeaderboardConcurrencyAndRepairTests.swift
//
// Two properties a live class activity depends on when a whole class submits
// at once (docs/class-activities.md):
//
//   * RACE-FREE BEST-SO-FAR. Results that land together cannot undo each
//     other: the leaderboard row and the `highestMetric` record end at the
//     best value whatever order the writes interleave in (`writeBestSoFar`).
//   * A LOST WRITE IS REPAIRED. A leaderboard write that failed at ingest is
//     rebuilt from the stored results (`repairLeaderboardEntries`), and the
//     queue that schedules it joins a burst of failures into one repair and
//     retries a repair that fails (`LeaderboardRepairQueue`).

import Core
import Fluent
import Foundation
import Logging
import Synchronization
import Testing
import VaporTesting

@testable import APIServer

@Suite struct LeaderboardConcurrencyAndRepairTests {

    private static let topScore = Achievement(
        id: "top_score", name: "Top score", scope: .record,
        reward: AchievementReward(type: .title, label: "Top score"),
        recordDimension: .highestMetric)

    private func activityManifest() throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")],
            language: nil,
            activity: ClassActivity(kind: .bestMetric),
            achievements: [Self.topScore])
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    /// A best-metric setup and `studentCount` enrolled students.
    private func fixture(
        _ app: Application, prefix: String, studentCount: Int
    ) async throws -> (setupID: String, students: [UUID]) {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let setupID = "\(prefix)_setup"
        try await APITestSetup(
            id: setupID, manifest: try activityManifest(),
            zipPath: app.testSetupsDirectory + "\(setupID).zip", courseID: courseID
        ).save(on: app.db)
        _ = try await arInsertAssignment(testSetupID: setupID, title: "Board \(prefix)", isOpen: true, on: app)
        var students: [UUID] = []
        for index in 0..<studentCount {
            let student = try await arInsertStudent(username: "\(prefix)_s\(index)", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            students.append(try student.requireID())
        }
        return (setupID, students)
    }

    private func metricOutcome(_ metric: Double) -> TestOutcome {
        .stub("m", status: .pass, metric: metric)
    }

    private func holder(_ app: Application, setupID: String) async throws -> APIClassAchievement? {
        try await APIClassAchievement.query(on: app.db)
            .filter(\.$testSetupID == setupID)
            .filter(\.$achievementID == Self.topScore.id)
            .first()
    }

    // MARK: - Race-free best-so-far

    @Test func concurrentResultsForOneStudentEndAtTheirBest() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "race_one", studentCount: 1)
            let student = try #require(fx.students.first)
            let metrics = (1...20).map(Double.init).shuffled()
            for index in metrics.indices {
                _ = try await arInsertSubmission(
                    id: "race_one_\(index)", testSetupID: fx.setupID, userID: student, on: app)
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (index, metric) in metrics.enumerated() {
                    group.addTask {
                        try await recordLeaderboardEntry(
                            testSetupID: fx.setupID, userID: student, submissionID: "race_one_\(index)",
                            outcomes: [metricOutcome(metric)], on: app.db)
                    }
                }
                try await group.waitForAll()
            }

            let rows = try await leaderboardEntries(testSetupID: fx.setupID, on: app.db)
            let best = try #require(metrics.firstIndex(of: 20))
            #expect(rows.count == 1)
            #expect(rows.first?.metric == 20)
            #expect(rows.first?.submissionID == "race_one_\(best)")
        }
    }

    @Test func concurrentResultsAcrossTheClassCrownTheBest() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "race_class", studentCount: 12)
            let metrics = fx.students.indices.map { Double($0 + 1) }.shuffled()
            for (index, student) in fx.students.enumerated() {
                _ = try await arInsertSubmission(
                    id: "race_class_\(index)", testSetupID: fx.setupID, userID: student, on: app)
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (index, student) in fx.students.enumerated() {
                    let metric = metrics[index]
                    group.addTask {
                        try await recordLeaderboardEntry(
                            testSetupID: fx.setupID, userID: student, submissionID: "race_class_\(index)",
                            outcomes: [metricOutcome(metric)], on: app.db)
                    }
                }
                try await group.waitForAll()
            }

            let winner = try #require(metrics.firstIndex(of: Double(fx.students.count)))
            let record = try #require(try await holder(app, setupID: fx.setupID))
            #expect(record.metricValue == Double(fx.students.count))
            #expect(record.userID == fx.students[winner])
            #expect(record.submissionID == "race_class_\(winner)")
            #expect(try await leaderboardEntries(testSetupID: fx.setupID, on: app.db).count == fx.students.count)
        }
    }

    @Test func aWorseResultLandingLastLeavesTheBestInPlace() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "late", studentCount: 1)
            let student = try #require(fx.students.first)
            for (id, metric) in [("late_best", 30.0), ("late_worse", 10.0)] {
                _ = try await arInsertSubmission(id: id, testSetupID: fx.setupID, userID: student, on: app)
                try await recordLeaderboardEntry(
                    testSetupID: fx.setupID, userID: student, submissionID: id,
                    outcomes: [metricOutcome(metric)], on: app.db)
            }
            let row = try #require(try await leaderboardEntries(testSetupID: fx.setupID, on: app.db).first)
            #expect(row.metric == 30)
            #expect(row.submissionID == "late_best")
            #expect(try await holder(app, setupID: fx.setupID)?.metricValue == 30)
        }
    }

    // MARK: - Repair from the stored results

    @Test func repairRebuildsMissingRowsAndTheRecordFromStoredResults() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "repair", studentCount: 2)
            let (a, b) = (fx.students[0], fx.students[1])
            // Stored results whose leaderboard writes never happened.
            for (id, user, metric) in [("repair_a1", a, 4.0), ("repair_a2", a, 9.0), ("repair_b1", b, 6.0)] {
                _ = try await arInsertSubmission(id: id, testSetupID: fx.setupID, userID: user, on: app)
                try await wrInsertResult(submissionID: id, outcomes: [metricOutcome(metric)], on: app)
            }
            #expect(try await leaderboardEntries(testSetupID: fx.setupID, on: app.db).isEmpty)

            try await repairLeaderboardEntries(testSetupID: fx.setupID, on: app.db)

            let rows = try await leaderboardEntries(testSetupID: fx.setupID, on: app.db)
            #expect(rows.map(\.submissionID) == ["repair_a2", "repair_b1"])
            #expect(rows.map(\.metric) == [9, 6])
            // A late row keeps the time the student reached the metric, not
            // the repair's, so it does not lose a tie for arriving late.
            let submitted = try #require(try await APISubmission.find("repair_a2", on: app.db)?.submittedAt)
            let reached = try #require(rows.first?.reachedAt)
            #expect(abs(reached.timeIntervalSince(submitted)) < 0.001)
            let record = try #require(try await holder(app, setupID: fx.setupID))
            #expect(record.userID == a)
            #expect(record.metricValue == 9)
        }
    }

    @Test func repairKeepsTheEarlierSubmissionOnATie() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "tie", studentCount: 1)
            let student = try #require(fx.students.first)
            for id in ["tie_1", "tie_2"] {
                _ = try await arInsertSubmission(id: id, testSetupID: fx.setupID, userID: student, on: app)
                try await wrInsertResult(submissionID: id, outcomes: [metricOutcome(5)], on: app)
            }
            try await repairLeaderboardEntries(testSetupID: fx.setupID, on: app.db)
            #expect(try await leaderboardEntries(testSetupID: fx.setupID, on: app.db).first?.submissionID == "tie_1")
        }
    }

    @Test func repairNeverLowersARowAndSkipsWhatIngestSkips() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "keep", studentCount: 1)
            let student = try #require(fx.students.first)
            // The row already holds 50 from a result that did land.
            _ = try await arInsertSubmission(id: "keep_best", testSetupID: fx.setupID, userID: student, on: app)
            try await recordLeaderboardEntry(
                testSetupID: fx.setupID, userID: student, submissionID: "keep_best",
                outcomes: [metricOutcome(50)], on: app.db)
            // A stored worse result, and a staff run that reported more.
            _ = try await arInsertSubmission(id: "keep_worse", testSetupID: fx.setupID, userID: student, on: app)
            try await wrInsertResult(submissionID: "keep_worse", outcomes: [metricOutcome(20)], on: app)
            let staff = try await arInsertUser(username: "keep_staff", role: "instructor", on: app)
            try await arEnrollStudentInTestCourse(staff, on: app)
            _ = try await arInsertSubmission(
                id: "keep_staff_run", testSetupID: fx.setupID, userID: try staff.requireID(), on: app)
            try await wrInsertResult(submissionID: "keep_staff_run", outcomes: [metricOutcome(999)], on: app)

            try await repairLeaderboardEntries(testSetupID: fx.setupID, on: app.db)

            let rows = try await leaderboardEntries(testSetupID: fx.setupID, on: app.db)
            #expect(rows.count == 1)
            #expect(rows.first?.submissionID == "keep_best")
            #expect(rows.first?.metric == 50)
        }
    }
}

// MARK: - The repair queue

@Suite(.timeLimit(.minutes(1))) struct LeaderboardRepairQueueTests {

    private let logger = Logger(label: "leaderboard-repair-test")

    private struct RepairFailed: Error {}

    @Test func repairsAskedForBeforeOneStartsJoinIt() async throws {
        let queue = LeaderboardRepairQueue(delays: [.milliseconds(50)])
        let runs = Mutex(0)
        let first = await queue.schedule("setup", logger: logger) { runs.withLock { $0 += 1 } }
        let second = await queue.schedule("setup", logger: logger) { runs.withLock { $0 += 1 } }
        #expect(second == nil)
        try await #require(first).value
        #expect(runs.withLock { $0 } == 1)
        #expect(await queue.isWaiting("setup") == false)
    }

    @Test func eachAssignmentGetsItsOwnRepair() async throws {
        let queue = LeaderboardRepairQueue(delays: [.milliseconds(10)])
        let runs = Mutex(0)
        let one = await queue.schedule("one", logger: logger) { runs.withLock { $0 += 1 } }
        let two = await queue.schedule("two", logger: logger) { runs.withLock { $0 += 1 } }
        try await #require(one).value
        try await #require(two).value
        #expect(runs.withLock { $0 } == 2)
    }

    @Test func aFailedRepairIsTriedAgain() async throws {
        let queue = LeaderboardRepairQueue(delays: [.milliseconds(10), .milliseconds(10), .milliseconds(10)])
        let attempts = Mutex(0)
        let task = await queue.schedule("setup", logger: logger) {
            let attempt = attempts.withLock { count in
                count += 1
                return count
            }
            if attempt < 2 { throw RepairFailed() }
        }
        try await #require(task).value
        #expect(attempts.withLock { $0 } == 2)
        #expect(await queue.isWaiting("setup") == false)
    }

    @Test func aRepairThatKeepsFailingGivesUpAfterItsAttempts() async throws {
        let queue = LeaderboardRepairQueue(delays: [.milliseconds(5), .milliseconds(5), .milliseconds(5)])
        let attempts = Mutex(0)
        let task = await queue.schedule("setup", logger: logger) {
            attempts.withLock { $0 += 1 }
            throw RepairFailed()
        }
        try await #require(task).value
        #expect(attempts.withLock { $0 } == 3)
        // Given up, so the next failed write can schedule a fresh one.
        #expect(await queue.isWaiting("setup") == false)
        #expect(await queue.schedule("setup", logger: logger) {} != nil)
    }
}
