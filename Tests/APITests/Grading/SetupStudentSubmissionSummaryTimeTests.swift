// Tests/APITests/Grading/SetupStudentSubmissionSummaryTimeTests.swift
//
// The roster's latest-submission time comes from the ranked summary row
// (`submissionSummaryByStudent`), not from a second read by id. These pin
// that the time is the latest attempt's own, and that a missing time stays
// nil. They run the real SQL on Postgres.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct SetupStudentSubmissionSummaryTimeTests {

    private func setSubmittedAt(_ date: Date?, id: String, on app: Application) async throws {
        try await APISubmission.query(on: app.db)
            .filter(\.$id == id)
            .set(\.$submittedAt, to: date)
            .update()
    }

    @Test func summaryCarriesTheLatestAttemptsTime() async throws {
        try await withWebRoutesApp(prefix: "chickadee-agg-time") { app in
            _ = try await loginUser(username: "student1", password: "pass", role: "student", on: app)
            let user = try await wrStudentUser(on: app)
            let userID = try user.requireID()

            try await wrInsertSetup(id: "aggt_setup", on: app)
            _ = try await wrInsertSubmission(
                id: "aggt_1", testSetupID: "aggt_setup", userID: userID, attemptNumber: 1, on: app)
            _ = try await wrInsertSubmission(
                id: "aggt_2", testSetupID: "aggt_setup", userID: userID, attemptNumber: 2, on: app)
            let earlier = Date(timeIntervalSince1970: 1_790_000_000)
            let later = Date(timeIntervalSince1970: 1_790_003_600)
            try await setSubmittedAt(earlier, id: "aggt_1", on: app)
            try await setSubmittedAt(later, id: "aggt_2", on: app)

            let summary = try await submissionSummaryByStudent(
                setupID: "aggt_setup", studentIDs: [userID], on: app.db)

            let row = try #require(summary[userID])
            #expect(row.latestSubmissionID == "aggt_2")
            let time = try #require(row.latestSubmittedAt)
            #expect(abs(time.timeIntervalSince(later)) < 0.001)
        }
    }

    @Test func summaryKeepsAMissingTimeNil() async throws {
        try await withWebRoutesApp(prefix: "chickadee-agg-time") { app in
            _ = try await loginUser(username: "student1", password: "pass", role: "student", on: app)
            let user = try await wrStudentUser(on: app)
            let userID = try user.requireID()

            try await wrInsertSetup(id: "aggt_null", on: app)
            _ = try await wrInsertSubmission(
                id: "aggt_n1", testSetupID: "aggt_null", userID: userID, attemptNumber: 1, on: app)
            try await setSubmittedAt(nil, id: "aggt_n1", on: app)

            let summary = try await submissionSummaryByStudent(
                setupID: "aggt_null", studentIDs: [userID], on: app.db)

            let row = try #require(summary[userID])
            #expect(row.latestSubmissionID == "aggt_n1")
            #expect(row.latestSubmittedAt == nil)
            #expect(row.submissionCount == 1)
        }
    }
}
