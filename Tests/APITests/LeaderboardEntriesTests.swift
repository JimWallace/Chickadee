// Tests/APITests/LeaderboardEntriesTests.swift
//
// The materialised leaderboard behind a class activity (docs/class-activities.md):
// one row per (assignment, student), best metric so far.
//
// The properties asserted are the ones the page and the record depend on:
//
//   * BEST-SO-FAR, so a worse later run and a replayed report leave the row
//     alone and the number never retreats;
//   * GATED ON THE ACTIVITY, so an ordinary lab whose script happens to emit a
//     metric accumulates nothing;
//   * ROSTER-SCOPED, so a staff test run never takes a rank;
//   * the `highestMetric` record follows the same event, higher wins.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct LeaderboardEntriesTests {

    private func outcome(_ name: String, metric: Double?, status: TestStatus = .pass) -> TestOutcome {
        TestOutcome(
            testName: name, testClass: nil, tier: .pub, status: status,
            shortResult: status.defaultShortResult, longResult: nil, metric: metric,
            executionTimeMs: 1, memoryUsageBytes: nil,
            attemptNumber: 1, isFirstPassSuccess: false)
    }

    private func activityManifest(_ kind: ActivityKind, records: [Achievement] = []) throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")],
            activity: ClassActivity(kind: kind),
            achievements: records)
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    /// A setup + assignment + two enrolled students.
    private func fixture(
        _ app: Application, prefix: String, manifest: String
    ) async throws -> (setupID: String, a: APIUser, b: APIUser) {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let setupID = "\(prefix)_setup"
        let setup = APITestSetup(
            id: setupID, manifest: manifest,
            zipPath: app.testSetupsDirectory + "\(setupID).zip", courseID: courseID)
        try await setup.save(on: app.db)
        _ = try await arInsertAssignment(
            testSetupID: setupID, title: "Race \(prefix)", isOpen: true, on: app)
        let a = try await arInsertStudent(username: "\(prefix)_a", on: app)
        try await arEnrollStudentInTestCourse(a, on: app)
        let b = try await arInsertStudent(username: "\(prefix)_b", on: app)
        try await arEnrollStudentInTestCourse(b, on: app)
        return (setupID, a, b)
    }

    private func record(
        _ app: Application, setupID: String, user: APIUser, submissionID: String,
        outcomes: [TestOutcome]
    ) async throws {
        _ = try await arInsertSubmission(
            id: submissionID, testSetupID: setupID, userID: try user.requireID(), on: app)
        try await recordLeaderboardEntry(
            testSetupID: setupID, userID: try user.requireID(), submissionID: submissionID,
            outcomes: outcomes, on: app.db)
    }

    // MARK: - The submission-level metric

    @Test func submissionMetricIsTheHighestReportedAndNilWhenNone() {
        #expect(submissionMetric(from: [outcome("a", metric: 3), outcome("b", metric: 7)]) == 7)
        #expect(submissionMetric(from: [outcome("a", metric: nil)]) == nil)
        #expect(submissionMetric(from: []) == nil)
        // A failing run's metric still counts: the script decides whether to
        // report one on failure.
        #expect(submissionMetric(from: [outcome("a", metric: 2, status: .fail)]) == 2)
    }

    // MARK: - Best so far

    @Test func bestMetricWinsAndAWorseRunLeavesTheRowAlone() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "best", manifest: try activityManifest(.bestMetric))
            try await record(
                app, setupID: fx.setupID, user: fx.a, submissionID: "best_1",
                outcomes: [outcome("m", metric: 10)])
            try await record(
                app, setupID: fx.setupID, user: fx.a, submissionID: "best_2",
                outcomes: [outcome("m", metric: 25)])
            try await record(
                app, setupID: fx.setupID, user: fx.a, submissionID: "best_3",
                outcomes: [outcome("m", metric: 12)])

            let rows = try await leaderboardEntries(testSetupID: fx.setupID, on: app.db)
            #expect(rows.count == 1)
            #expect(rows.first?.metric == 25)
            #expect(rows.first?.submissionID == "best_2")
        }
    }

    @Test func replayedReportIsANoOp() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "replay", manifest: try activityManifest(.bestMetric))
            try await record(
                app, setupID: fx.setupID, user: fx.a, submissionID: "replay_1",
                outcomes: [outcome("m", metric: 10)])
            let before = try await leaderboardEntries(testSetupID: fx.setupID, on: app.db)
            // The worker re-reports the same collection (a retest, a retry).
            try await recordLeaderboardEntry(
                testSetupID: fx.setupID, userID: try fx.a.requireID(), submissionID: "replay_1",
                outcomes: [outcome("m", metric: 10)], on: app.db)
            let after = try await leaderboardEntries(testSetupID: fx.setupID, on: app.db)
            #expect(after.count == 1)
            #expect(after.first?.reachedAt == before.first?.reachedAt)
        }
    }

    @Test func rankingIsBestFirst() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "rank", manifest: try activityManifest(.beatTheInstructor))
            try await record(
                app, setupID: fx.setupID, user: fx.a, submissionID: "rank_a",
                outcomes: [outcome("m", metric: 4)])
            try await record(
                app, setupID: fx.setupID, user: fx.b, submissionID: "rank_b",
                outcomes: [outcome("m", metric: 9)])
            let rows = try await leaderboardEntries(testSetupID: fx.setupID, on: app.db)
            #expect(rows.map(\.submissionID) == ["rank_b", "rank_a"])
        }
    }

    // MARK: - Gates

    @Test func anOrdinaryAssignmentAccumulatesNothing() async throws {
        try await withAssignmentRoutesApp { app in
            let plain = #"{"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10}"#
            let fx = try await fixture(app, prefix: "plain", manifest: plain)
            try await record(
                app, setupID: fx.setupID, user: fx.a, submissionID: "plain_1",
                outcomes: [outcome("m", metric: 10)])
            #expect(try await leaderboardEntries(testSetupID: fx.setupID, on: app.db).isEmpty)
        }
    }

    @Test func aCollectionWithNoMetricAccumulatesNothing() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "nometric", manifest: try activityManifest(.bestMetric))
            try await record(
                app, setupID: fx.setupID, user: fx.a, submissionID: "nometric_1",
                outcomes: [outcome("m", metric: nil)])
            #expect(try await leaderboardEntries(testSetupID: fx.setupID, on: app.db).isEmpty)
        }
    }

    @Test func staffTestRunsNeverRank() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, prefix: "staff", manifest: try activityManifest(.bestMetric))
            let ta = try await arInsertUser(username: "staff_ta", role: "instructor", on: app)
            try await arEnrollStudentInTestCourse(ta, on: app)  // enrolls staff as .instructor
            try await record(
                app, setupID: fx.setupID, user: ta, submissionID: "staff_1",
                outcomes: [outcome("m", metric: 999)])
            #expect(try await leaderboardEntries(testSetupID: fx.setupID, on: app.db).isEmpty)
        }
    }

    // MARK: - The highestMetric record

    @Test func highestMetricRecordFollowsTheLeaderboardHigherWins() async throws {
        try await withAssignmentRoutesApp { app in
            let record = Achievement(
                id: "top_score", name: "Top score", scope: .record,
                reward: AchievementReward(type: .title, label: "Top score"),
                recordDimension: .highestMetric)
            let fx = try await fixture(
                app, prefix: "rec", manifest: try activityManifest(.bestMetric, records: [record]))
            try await self.record(
                app, setupID: fx.setupID, user: fx.a, submissionID: "rec_a",
                outcomes: [outcome("m", metric: 4)])
            try await self.record(
                app, setupID: fx.setupID, user: fx.b, submissionID: "rec_b",
                outcomes: [outcome("m", metric: 9)])
            // A's later, worse run must not dethrone B; a tie keeps B too.
            try await self.record(
                app, setupID: fx.setupID, user: fx.a, submissionID: "rec_a2",
                outcomes: [outcome("m", metric: 9)])

            let holders = try await APIClassAchievement.query(on: app.db)
                .filter(\.$testSetupID == fx.setupID)
                .all()
            #expect(holders.count == 1)
            #expect(holders.first?.achievementID == "top_score")
            #expect(holders.first?.userID == (try fx.b.requireID()))
            #expect(holders.first?.metricValue == 9)
        }
    }

    /// The 100% award path must leave a `highestMetric` record alone: it is
    /// crowned on the leaderboard path, where the metric lives.
    @Test func the100PercentPathDoesNotAwardHighestMetric() async throws {
        try await withAssignmentRoutesApp { app in
            let record = Achievement(
                id: "top_score", name: "Top score", scope: .record,
                reward: AchievementReward(type: .title, label: "Top score"),
                recordDimension: .highestMetric)
            let fx = try await fixture(
                app, prefix: "hundred", manifest: try activityManifest(.bestMetric, records: [record]))
            _ = try await arInsertSubmission(
                id: "hundred_1", testSetupID: fx.setupID, userID: try fx.a.requireID(), on: app)
            try await awardClassBadgesFor100Percent(
                testSetupID: fx.setupID, userID: try fx.a.requireID(), submissionID: "hundred_1",
                executionTimeMs: 5, attemptNumber: 1, on: app.db)
            let holders = try await APIClassAchievement.query(on: app.db)
                .filter(\.$testSetupID == fx.setupID)
                .all()
            #expect(holders.isEmpty)
        }
    }
}
