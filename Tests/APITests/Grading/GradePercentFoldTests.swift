// Tests/APITests/Grading/GradePercentFoldTests.swift
//
// The SQL grade folds (`GradePercentSQL`) must give the number that
// `bestGradePercent(of:)` gives over the same rows. That includes the rule of
// `GradePercent.of` that only a full mark reads 100: an aggregate that rounded
// the best raw fraction read 199 of 200 points as 100.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized) struct GradePercentFoldTests {

    @Test(arguments: [
        (199.0, 200.0), (200.0, 200.0), (87.5, 100.0), (0.0, 10.0), (1.0, 3.0), (2.0, 3.0), (999.0, 1000.0),
        (210.0, 200.0),
    ])
    func foldOfOneRowMatchesGradePercent(earned: Double, total: Double) throws {
        let raw = earned / total * 100
        let full = GradePercent.isFullMark(earned: earned, total: total)
        let folded = GradePercentSQL.percent(bestFull: full ? raw : nil, bestPartial: full ? nil : raw)
        #expect(folded == GradePercent.of(earned: earned, total: total))
    }

    @Test func foldTakesTheHigherOfFullAndPartial() {
        #expect(GradePercentSQL.percent(bestFull: 100, bestPartial: 99.6) == 100)
        #expect(GradePercentSQL.percent(bestFull: nil, bestPartial: 99.6) == 99)
        #expect(GradePercentSQL.percent(bestFull: nil, bestPartial: nil) == nil)
    }

    /// Sets a result's grade columns directly, after the write path stamped
    /// them from the collection.
    private func setGradeColumns(
        _ result: APIResult, earned: Double?, total: Double?, pass: Int?, tests: Int?, on app: Application
    ) async throws {
        result.earnedPoints = earned
        result.totalPoints = total
        result.passCount = pass
        result.totalTests = tests
        try await result.save(on: app.db)
    }

    @Test func everyAggregateAgreesWithTheSwiftFold() async throws {
        try await withTestApp { app in
            _ = try await wrInsertSetup(id: "fold_setup", on: app)
            let almost = try await makeTestUser(on: app, username: "fold_almost").requireID()
            let full = try await makeTestUser(on: app, username: "fold_full").requireID()
            let legacy = try await makeTestUser(on: app, username: "fold_legacy").requireID()

            // 199 of 200 points, twice: reads 99, not 100.
            for (index, id) in ["fold_a1", "fold_a2"].enumerated() {
                _ = try await wrInsertSubmission(
                    id: id, testSetupID: "fold_setup", userID: almost, attemptNumber: index + 1, on: app)
                let result = try await wrInsertResult(submissionID: id, on: app)
                try await setGradeColumns(result, earned: 199, total: 200, pass: nil, tests: nil, on: app)
            }
            // 87.5 % and a full mark: reads 100.
            _ = try await wrInsertSubmission(id: "fold_f1", testSetupID: "fold_setup", userID: full, on: app)
            let partial = try await wrInsertResult(submissionID: "fold_f1", on: app)
            try await setGradeColumns(partial, earned: 87.5, total: 100, pass: nil, tests: nil, on: app)
            let complete = try await wrInsertResult(submissionID: "fold_f1", source: "browser", on: app)
            try await setGradeColumns(complete, earned: 200, total: 200, pass: nil, tests: nil, on: app)
            // A result with no grade columns: graded from its collection, 1 of 2.
            _ = try await wrInsertSubmission(id: "fold_l1", testSetupID: "fold_setup", userID: legacy, on: app)
            let old = try await wrInsertResult(
                submissionID: "fold_l1",
                outcomes: [wrMakeOutcome(name: "t1", status: .pass), wrMakeOutcome(name: "t2", status: .fail)],
                on: app)
            try await setGradeColumns(old, earned: nil, total: nil, pass: nil, tests: nil, on: app)

            let students = [almost, full, legacy]
            let byPair = try await bestGradePercentByStudentAndSetup(
                setupIDs: ["fold_setup"], studentIDs: students, on: app.db)
            #expect(byPair[StudentSetupKey(userID: almost, setupID: "fold_setup")] == 99)
            #expect(byPair[StudentSetupKey(userID: full, setupID: "fold_setup")] == 100)
            #expect(byPair[StudentSetupKey(userID: legacy, setupID: "fold_setup")] == 50)

            // The reference: the Swift fold over the same rows.
            for student in students {
                let submissionIDs = try await APISubmission.query(on: app.db)
                    .filter(\.$userID == student).all().compactMap(\.id)
                let summaries = try await gradeSummariesBySubmissionID(for: submissionIDs, on: app.db)
                let reference = summaries.values.compactMap { bestGradePercent(of: $0) }.max()
                #expect(byPair[StudentSetupKey(userID: student, setupID: "fold_setup")] == reference)
            }

            // The roster and the dashboard use the same fold. Neither reads
            // a column-less row, as before.
            let roster = try await bestGradePercentByStudent(
                setupID: "fold_setup", studentIDs: students, on: app.db)
            #expect(roster[almost] == 99)
            #expect(roster[full] == 100)
            let dashboard = try await studentBestGradePercentBySetup(
                userID: almost, setupIDs: ["fold_setup"], on: app.db)
            #expect(dashboard["fold_setup"] == 99)
        }
    }
}
