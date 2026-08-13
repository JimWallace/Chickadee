// Tests/APITests/StudentSubmissionAggregatesTests.swift
//
// Direct tests for the dashboard's SQL-side aggregation (#1382 item 2):
// latest-pick + count, the best-percent fold (both grade branches, the
// half-away-from-zero boundary, the nil-columns row), and the scoping rules
// (other users, validation runs, out-of-scope setups). These run the real
// SQL on whichever driver the suite is configured for — SQLite in the
// default lane, Postgres in api-tests-postgres.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct StudentSubmissionAggregatesTests {

    @Test func summaryPicksLatestAndCountsPerSetup() async throws {
        try await withWebRoutesApp(prefix: "chickadee-agg") { app in
            _ = try await loginUser(username: "student1", password: "pass", role: "student", on: app)
            let user = try await wrStudentUser(on: app)
            let userID = try user.requireID()
            _ = try await loginUser(
                username: "student2", password: "pass", role: "student", on: app)
            let other = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "student2").first())
            let otherID = try other.requireID()

            try await wrInsertSetup(id: "agg_a", on: app)
            try await wrInsertSetup(id: "agg_b", on: app)
            try await wrInsertSubmission(
                id: "agg_a1", testSetupID: "agg_a", userID: userID, attemptNumber: 1, on: app)
            try await wrInsertSubmission(
                id: "agg_a2", testSetupID: "agg_a", userID: userID, attemptNumber: 2, on: app)
            try await wrInsertSubmission(
                id: "agg_b1", testSetupID: "agg_b", userID: userID, attemptNumber: 1, on: app)
            // Noise the aggregate must ignore: another user's attempt, a
            // validation run, and a setup outside the requested scope.
            try await wrInsertSubmission(
                id: "agg_other", testSetupID: "agg_a", userID: otherID, attemptNumber: 1, on: app)
            let validation = APISubmission(
                id: "agg_validation", testSetupID: "agg_a",
                zipPath: app.submissionsDirectory + "agg_validation.py",
                attemptNumber: 3, userID: userID, kind: APISubmission.Kind.validation)
            try await validation.save(on: app.db)
            try await wrInsertSetup(id: "agg_out", on: app)
            try await wrInsertSubmission(
                id: "agg_out1", testSetupID: "agg_out", userID: userID, attemptNumber: 1, on: app)

            let summary = try await studentSubmissionSummaryBySetup(
                userID: userID, setupIDs: ["agg_a", "agg_b"], on: app.db)

            #expect(summary.count == 2)
            #expect(summary["agg_a"]?.latestSubmissionID == "agg_a2")
            #expect(summary["agg_a"]?.submissionCount == 2)
            #expect(summary["agg_b"]?.latestSubmissionID == "agg_b1")
            #expect(summary["agg_b"]?.submissionCount == 1)
        }
    }

    @Test func summaryIsEmptyForNoSetupsOrNoSubmissions() async throws {
        try await withWebRoutesApp(prefix: "chickadee-agg") { app in
            _ = try await loginUser(username: "student1", password: "pass", role: "student", on: app)
            let user = try await wrStudentUser(on: app)
            let userID = try user.requireID()

            let empty = try await studentSubmissionSummaryBySetup(
                userID: userID, setupIDs: [], on: app.db)
            #expect(empty.isEmpty)

            try await wrInsertSetup(id: "agg_none", on: app)
            let none = try await studentSubmissionSummaryBySetup(
                userID: userID, setupIDs: ["agg_none"], on: app.db)
            #expect(none.isEmpty)
        }
    }

    @Test func bestPercentTakesMaxAcrossAttemptsAndSources() async throws {
        try await withWebRoutesApp(prefix: "chickadee-agg") { app in
            _ = try await loginUser(username: "student1", password: "pass", role: "student", on: app)
            let user = try await wrStudentUser(on: app)
            let userID = try user.requireID()

            try await wrInsertSetup(id: "agg_best", on: app)
            try await wrInsertSubmission(
                id: "agg_best1", testSetupID: "agg_best", userID: userID, attemptNumber: 1, on: app)
            // Browser result 3/4 = 75%, worker regrade 1/4 = 25%: best is 75.
            try await wrInsertResult(
                submissionID: "agg_best1",
                outcomes: [
                    wrMakeOutcome(name: "t1", status: .pass),
                    wrMakeOutcome(name: "t2", status: .pass),
                    wrMakeOutcome(name: "t3", status: .pass),
                    wrMakeOutcome(name: "t4", status: .fail),
                ],
                source: "browser", on: app)
            try await wrInsertResult(
                submissionID: "agg_best1",
                outcomes: [
                    wrMakeOutcome(name: "t1", status: .pass),
                    wrMakeOutcome(name: "t2", status: .fail),
                    wrMakeOutcome(name: "t3", status: .fail),
                    wrMakeOutcome(name: "t4", status: .fail),
                ],
                source: "worker", on: app)
            // A second attempt at 2/4 = 50% must not displace attempt 1's 75.
            try await wrInsertSubmission(
                id: "agg_best2", testSetupID: "agg_best", userID: userID, attemptNumber: 2, on: app)
            try await wrInsertResult(
                submissionID: "agg_best2",
                outcomes: [
                    wrMakeOutcome(name: "t1", status: .pass),
                    wrMakeOutcome(name: "t2", status: .pass),
                    wrMakeOutcome(name: "t3", status: .fail),
                    wrMakeOutcome(name: "t4", status: .fail),
                ], on: app)

            let best = try await studentBestGradePercentBySetup(
                userID: userID, setupIDs: ["agg_best"], on: app.db)
            #expect(best == ["agg_best": 75])
        }
    }

    @Test func bestPercentPrefersWeightedBranchAndRoundsHalfAwayFromZero() async throws {
        try await withWebRoutesApp(prefix: "chickadee-agg") { app in
            _ = try await loginUser(username: "student1", password: "pass", role: "student", on: app)
            let user = try await wrStudentUser(on: app)
            let userID = try user.requireID()

            try await wrInsertSetup(id: "agg_weighted", on: app)
            try await wrInsertSubmission(
                id: "agg_w1", testSetupID: "agg_weighted", userID: userID, attemptNumber: 1, on: app)
            // Weighted 7/8 points = 87.5 → rounds to 88, and the weighted
            // branch wins over the row's own 1/4 pass count (25%).
            let weighted = APIResult(id: "agg_res_w", submissionID: "agg_w1", source: "worker")
            try await weighted.saveWithCollection(
                json: #"{"submissionID":"agg_w1","earnedPoints":7,"totalPoints":8,"passCount":1,"totalTests":4}"#,
                on: app.db)

            let best = try await studentBestGradePercentBySetup(
                userID: userID, setupIDs: ["agg_weighted"], on: app.db)
            #expect(best == ["agg_weighted": 88])
        }
    }

    @Test func bestPercentOmitsAnAllFailZero() async throws {
        try await withWebRoutesApp(prefix: "chickadee-agg") { app in
            _ = try await loginUser(username: "student1", password: "pass", role: "student", on: app)
            let user = try await wrStudentUser(on: app)
            let userID = try user.requireID()

            try await wrInsertSetup(id: "agg_zero", on: app)
            try await wrInsertSubmission(
                id: "agg_z1", testSetupID: "agg_zero", userID: userID, attemptNumber: 1, on: app)
            try await wrInsertResult(
                submissionID: "agg_z1",
                outcomes: [
                    wrMakeOutcome(name: "t1", status: .fail),
                    wrMakeOutcome(name: "t2", status: .fail),
                ], on: app)

            // A best of exactly 0 stays out of the map — the pre-aggregate
            // fold only admitted a grade above its 0 sentinel, so an all-fail
            // student shows no grade rather than "0%".
            let best = try await studentBestGradePercentBySetup(
                userID: userID, setupIDs: ["agg_zero"], on: app.db)
            #expect(best.isEmpty)
        }
    }

    @Test func bestPercentSkipsRowsWithNoGradeColumns() async throws {
        try await withWebRoutesApp(prefix: "chickadee-agg") { app in
            _ = try await loginUser(username: "student1", password: "pass", role: "student", on: app)
            let user = try await wrStudentUser(on: app)
            let userID = try user.requireID()

            try await wrInsertSetup(id: "agg_nograde", on: app)
            try await wrInsertSubmission(
                id: "agg_ng1", testSetupID: "agg_nograde", userID: userID, attemptNumber: 1, on: app)
            // A result whose blob carries no parseable grade leaves all four
            // columns nil; the fold reports no grade, matching
            // `APIResult.gradePercentValue`.
            let ungraded = APIResult(id: "agg_res_ng", submissionID: "agg_ng1", source: "worker")
            try await ungraded.saveWithCollection(json: "not json", on: app.db)

            let best = try await studentBestGradePercentBySetup(
                userID: userID, setupIDs: ["agg_nograde"], on: app.db)
            #expect(best.isEmpty)
        }
    }
}
