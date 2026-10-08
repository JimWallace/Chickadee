// Tests/APITests/ClassRecordRecomputeTests.swift
//
// A retest result recomputes the 100%-earned class records (first to solve,
// fastest, fewest attempts) from each student submission's latest result
// (#2054, A12). Before, the records only ever moved to a better result: a
// worse retest kept the holder, and after a retest-all first to solve went to
// whichever retest result arrived first.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized)
struct ClassRecordRecomputeTests {

    private func effects(_ app: Application) -> ResultIngestEffects {
        ResultIngestEffects(application: app, db: app.db, logger: app.logger)
    }

    private func collection(
        _ submissionID: String, setupID: String, passed: Bool, executionTimeMs: Int = 50
    ) -> TestOutcomeCollection {
        let outcomes = [wrMakeOutcome(name: "t1", status: passed ? .pass : .fail)]
        return TestOutcomeCollection(
            submissionID: submissionID, testSetupID: setupID, attemptNumber: 1, buildStatus: .passed,
            compilerOutput: nil, outcomes: outcomes, totalTests: 1,
            passCount: passed ? 1 : 0, failCount: passed ? 0 : 1,
            errorCount: 0, timeoutCount: 0, executionTimeMs: executionTimeMs, runnerVersion: "test",
            timestamp: Date())
    }

    /// An enrolled student with one submission, submitted at `submittedAt`.
    private func student(
        _ name: String, setupID: String, submittedAt: Date, on app: Application
    ) async throws -> APISubmission {
        let user = try await arInsertStudent(username: name, on: app)
        try await arEnrollStudentInTestCourse(user, on: app)
        let submission = try await arInsertSubmission(
            id: "\(name)_sub", testSetupID: setupID, userID: try user.requireID(), on: app)
        submission.submittedAt = submittedAt
        try await submission.update(on: app.db)
        return submission
    }

    /// Stores `collection` as a result row received at `receivedAt`.
    private func store(
        _ collection: TestOutcomeCollection, for submission: APISubmission, receivedAt: Date,
        on app: Application
    ) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try #require(String(data: try encoder.encode(collection), encoding: .utf8))
        let result = APIResult(id: "res_\(UUID().uuidString.prefix(8))", submissionID: try submission.requireID())
        try await result.saveWithCollection(json: json, on: app.db)
        result.receivedAt = receivedAt
        try await result.update(on: app.db)
    }

    /// Stores `collection`, then applies the ingest effects as the worker
    /// report does.
    private func ingest(
        _ collection: TestOutcomeCollection, for submission: APISubmission, receivedAt: Date,
        on app: Application
    ) async throws {
        try await store(collection, for: submission, receivedAt: receivedAt, on: app)
        await effects(app).apply(submission: submission, collection: collection)
    }

    private func holder(
        _ achievementID: String, setupID: String, on app: Application
    ) async throws -> APIClassAchievement? {
        try await APIClassAchievement.query(on: app.db)
            .filter(\.$testSetupID == setupID)
            .filter(\.$achievementID == achievementID)
            .first()
    }

    private func markRetested(_ submission: APISubmission, on app: Application) async throws {
        submission.retestedAt = Date()
        try await submission.update(on: app.db)
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aRetestBelowFullMarksTakesTheRecordsAway() async throws {
        try await withAssignmentRoutesApp { app in
            let setupID = "a12_drop_setup"
            _ = try await arInsertSetup(id: setupID, on: app)
            let sub = try await student("a12_drop", setupID: setupID, submittedAt: t0, on: app)
            let id = try sub.requireID()

            try await ingest(collection(id, setupID: setupID, passed: true), for: sub, receivedAt: t0, on: app)
            #expect(try await holder("trailblazer", setupID: setupID, on: app) != nil)

            try await markRetested(sub, on: app)
            try await ingest(
                collection(id, setupID: setupID, passed: false), for: sub,
                receivedAt: t0.addingTimeInterval(60), on: app)
            #expect(try await holder("trailblazer", setupID: setupID, on: app) == nil)
            #expect(try await holder("speed_champion", setupID: setupID, on: app) == nil)
            #expect(try await holder("minimalist", setupID: setupID, on: app) == nil)
        }
    }

    @Test func aRetestAllGivesFirstToSolveToTheEarliestSubmitter() async throws {
        try await withAssignmentRoutesApp { app in
            let setupID = "a12_all_setup"
            _ = try await arInsertSetup(id: setupID, on: app)
            let early = try await student("a12_early", setupID: setupID, submittedAt: t0, on: app)
            let late = try await student(
                "a12_late", setupID: setupID, submittedAt: t0.addingTimeInterval(3600), on: app)

            // Neither solved it under the old suite.
            for sub in [early, late] {
                try await ingest(
                    collection(try sub.requireID(), setupID: setupID, passed: false), for: sub,
                    receivedAt: t0.addingTimeInterval(7200), on: app)
            }
            #expect(try await holder("trailblazer", setupID: setupID, on: app) == nil)

            // A retest-all: the later submitter's result arrives first.
            for sub in [late, early] {
                try await markRetested(sub, on: app)
                try await ingest(
                    collection(try sub.requireID(), setupID: setupID, passed: true), for: sub,
                    receivedAt: t0.addingTimeInterval(9000), on: app)
            }
            let record = try #require(try await holder("trailblazer", setupID: setupID, on: app))
            #expect(record.userID == early.userID)
            #expect(record.submissionID == early.id)
        }
    }

    @Test func fastestFollowsEachSubmissionsLatestResult() async throws {
        try await withAssignmentRoutesApp { app in
            let setupID = "a12_fast_setup"
            _ = try await arInsertSetup(id: setupID, on: app)
            let quick = try await student("a12_quick", setupID: setupID, submittedAt: t0, on: app)
            let steady = try await student(
                "a12_steady", setupID: setupID, submittedAt: t0.addingTimeInterval(60), on: app)
            try await ingest(
                collection(try quick.requireID(), setupID: setupID, passed: true, executionTimeMs: 50),
                for: quick, receivedAt: t0, on: app)
            try await ingest(
                collection(try steady.requireID(), setupID: setupID, passed: true, executionTimeMs: 80),
                for: steady, receivedAt: t0.addingTimeInterval(60), on: app)
            #expect(try await holder("speed_champion", setupID: setupID, on: app)?.userID == quick.userID)

            // The quick submission's retest is now the slower of the two.
            try await markRetested(quick, on: app)
            try await ingest(
                collection(try quick.requireID(), setupID: setupID, passed: true, executionTimeMs: 200),
                for: quick, receivedAt: t0.addingTimeInterval(600), on: app)
            let record = try #require(try await holder("speed_champion", setupID: setupID, on: app))
            #expect(record.userID == steady.userID)
            #expect(record.metricValue == 80)
            // First to solve stays with the earlier submitter, who still has 100%.
            #expect(try await holder("trailblazer", setupID: setupID, on: app)?.userID == quick.userID)
        }
    }

    /// A retest-all delivers its results at once. Each recompute waits for the
    /// one before it, so the last word sees every stored result.
    @Test func concurrentRetestResultsAgreeOnTheEarliestSubmitter() async throws {
        try await withAssignmentRoutesApp { app in
            let setupID = "a12_conc_setup"
            _ = try await arInsertSetup(id: setupID, on: app)
            var subs: [APISubmission] = []
            for index in 0..<6 {
                let sub = try await student(
                    "a12_conc_\(index)", setupID: setupID,
                    submittedAt: t0.addingTimeInterval(Double(index) * 60), on: app)
                try await markRetested(sub, on: app)
                try await store(
                    collection(try sub.requireID(), setupID: setupID, passed: true), for: sub,
                    receivedAt: t0.addingTimeInterval(3600), on: app)
                subs.append(sub)
            }
            let ingest = effects(app)
            let pairs = try subs.reversed().map { sub in
                (sub, collection(try sub.requireID(), setupID: setupID, passed: true))
            }
            await withTaskGroup(of: Void.self) { group in
                for (sub, result) in pairs {
                    group.addTask { await ingest.apply(submission: sub, collection: result) }
                }
            }
            #expect(try await holder("trailblazer", setupID: setupID, on: app)?.userID == subs[0].userID)
        }
    }

    /// Two submissions made at the same moment: the smaller submission id wins,
    /// so the holder never depends on query order.
    @Test func aTieGoesToTheSmallerSubmissionID() async throws {
        try await withAssignmentRoutesApp { app in
            let setupID = "a12_tie_setup"
            _ = try await arInsertSetup(id: setupID, on: app)
            let second = try await student("a12_tie_b", setupID: setupID, submittedAt: t0, on: app)
            let first = try await student("a12_tie_a", setupID: setupID, submittedAt: t0, on: app)
            for sub in [second, first] {
                try await markRetested(sub, on: app)
                try await ingest(
                    collection(try sub.requireID(), setupID: setupID, passed: true), for: sub,
                    receivedAt: t0, on: app)
            }
            #expect(try await holder("trailblazer", setupID: setupID, on: app)?.submissionID == "a12_tie_a_sub")
            #expect(try await holder("minimalist", setupID: setupID, on: app)?.submissionID == "a12_tie_a_sub")
        }
    }

    /// A retest whose build fails has no points, so it takes the record away
    /// too. The recompute runs before the build gate for exactly this case.
    @Test func aRetestWithAFailedBuildTakesTheRecordAway() async throws {
        try await withAssignmentRoutesApp { app in
            let setupID = "a12_build_setup"
            _ = try await arInsertSetup(id: setupID, on: app)
            let sub = try await student("a12_build", setupID: setupID, submittedAt: t0, on: app)
            let id = try sub.requireID()
            try await ingest(collection(id, setupID: setupID, passed: true), for: sub, receivedAt: t0, on: app)
            #expect(try await holder("trailblazer", setupID: setupID, on: app) != nil)

            try await markRetested(sub, on: app)
            let failedBuild = TestOutcomeCollection(
                submissionID: id, testSetupID: setupID, attemptNumber: 1, buildStatus: .failed,
                compilerOutput: "error", outcomes: [], totalTests: 0, passCount: 0, failCount: 0,
                errorCount: 0, timeoutCount: 0, executionTimeMs: 10, runnerVersion: "test", timestamp: Date())
            try await ingest(failedBuild, for: sub, receivedAt: t0.addingTimeInterval(60), on: app)
            #expect(try await holder("trailblazer", setupID: setupID, on: app) == nil)
        }
    }

    /// A staff member's submission never holds a record, retest or not.
    @Test func aStaffSubmissionNeverHoldsARecord() async throws {
        try await withAssignmentRoutesApp { app in
            let setupID = "a12_staff_setup"
            _ = try await arInsertSetup(id: setupID, on: app)
            let staff = try await arInsertUser(username: "a12_staff", role: "instructor", on: app)
            try await arEnrollStudentInTestCourse(staff, on: app)
            let sub = try await arInsertSubmission(
                id: "a12_staff_sub", testSetupID: setupID, userID: try staff.requireID(), on: app)
            try await markRetested(sub, on: app)
            try await ingest(
                collection(try sub.requireID(), setupID: setupID, passed: true), for: sub, receivedAt: t0,
                on: app)
            #expect(try await holder("trailblazer", setupID: setupID, on: app) == nil)
        }
    }
}
