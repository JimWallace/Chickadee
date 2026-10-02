// Tests/APITests/OneGradeFoldTests.swift
//
// Every grade surface agrees on "highest grade wins" (#1709). A browser
// result at 100 % followed by a worker regrade at 90 % reads as 100 % on the
// student's own history page, in the class-goal sweep and in the row the
// badge path reads, exactly as it does on the staff pages.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct OneGradeFoldTests {

    private func tenOutcomes(passing: Int) -> [TestOutcome] {
        (1...10).map { wrMakeOutcome(name: "t\($0)", status: $0 <= passing ? .pass : .fail) }
    }

    /// A browser 100 % and a later worker 90 % for one submission.
    private func seedPair(
        setupID: String, submissionID: String, on app: Application
    ) async throws
        -> (user: APIUser, browser: APIResult)
    {
        let user = try await wrStudentUser(on: app)
        try await wrEnrollUser(user, on: app)
        try await wrInsertSetup(id: setupID, on: app)
        try await wrInsertSubmission(
            id: submissionID, testSetupID: setupID, userID: try user.requireID(), on: app)
        let browser = try await wrInsertResult(
            submissionID: submissionID, outcomes: tenOutcomes(passing: 10), source: "browser", on: app)
        try await wrInsertResult(
            submissionID: submissionID, outcomes: tenOutcomes(passing: 9), source: "worker", on: app)
        return (user, browser)
    }

    @Test func theStudentHistoryPageShowsTheHighestGrade() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            _ = try await seedPair(setupID: "setup_fold_page", submissionID: "sub_fold_page", on: app)

            try await app.asyncTest(
                .GET, "/testsetups/setup_fold_page/history",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("100%"))
                    #expect(!html.contains("90%"))
                })
        }
    }

    @Test func theClassGoalSweepCountsTheHighestGrade() async throws {
        try await withWebRoutesApp { app in
            _ = try await wrLoginAsStudent(on: app)
            let seeded = try await seedPair(setupID: "setup_fold_sweep", submissionID: "sub_fold_sweep", on: app)
            let userID = try seeded.user.requireID()

            let best = try await bestAssignmentGradeByStudent(testSetupID: "setup_fold_sweep", on: app.db)
            #expect(best[userID] == 1.0)
        }
    }

    @Test func theBadgePathReadsTheRowTheGradeCameFrom() async throws {
        try await withWebRoutesApp { app in
            _ = try await wrLoginAsStudent(on: app)
            let seeded = try await seedPair(setupID: "setup_fold_row", submissionID: "sub_fold_row", on: app)

            let rows = try await bestGradeResultBySubmissionID(for: ["sub_fold_row"], on: app.db)
            #expect(rows["sub_fold_row"]?.id == seeded.browser.id)
        }
    }

    /// A submission whose results carry no grade still names a row, the
    /// newest, so the badge path can read its collection.
    @Test func anUngradedSubmissionFallsBackToItsNewestRow() {
        let older = APIResult(id: "res_old", submissionID: "sub_x", source: "worker")
        let newer = APIResult(id: "res_new", submissionID: "sub_x", source: "worker")
        let rows = bestGradeResultBySubmissionID([newer, older])
        #expect(rows["sub_x"]?.id == "res_new")
    }
}
