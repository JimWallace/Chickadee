// Tests/APITests/Grading/GradePercentFoldBranchTests.swift
//
// Every branch of the SQL grade fold (`GradePercentSQL`), run in Postgres and
// compared with the Swift fold over the same rows: points, pass count over
// total tests, the fall-through between them, a mark above the total, a mark
// inside the full-mark tolerance, and a partial mark that rounds to 100.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized) struct GradePercentFoldBranchTests {

    /// One result's grade columns, as stored.
    struct Columns: Sendable, CustomTestStringConvertible {
        let earned: Double?
        let total: Double?
        let pass: Int?
        let tests: Int?
        var testDescription: String {
            "earned \(earned.map { "\($0)" } ?? "nil")/\(total.map { "\($0)" } ?? "nil"), pass \(pass.map { "\($0)" } ?? "nil")/\(tests.map { "\($0)" } ?? "nil")"
        }
    }

    static let cases: [Columns] = [
        Columns(earned: nil, total: nil, pass: 3, tests: 4),  // pass/total: 75
        Columns(earned: nil, total: nil, pass: 4, tests: 4),  // pass/total, full: 100
        Columns(earned: 5, total: 0, pass: 1, tests: 2),  // total 0 falls through: 50
        Columns(earned: nil, total: 10, pass: 1, tests: 3),  // earned NULL falls through: 33
        Columns(earned: nil, total: nil, pass: 0, tests: 0),  // no grade
        Columns(earned: 210, total: 200, pass: nil, tests: nil),  // above the total: 105
        Columns(earned: 199.9999999999, total: 200, pass: nil, tests: nil),  // within 1e-9: full, 100
        Columns(earned: 199.99, total: 200, pass: nil, tests: nil),  // 99.995: partial, 99
        Columns(earned: 199, total: 200, pass: 200, tests: 200),  // points win over pass/total: 99
    ]

    @Test(arguments: cases)
    func sqlFoldMatchesSwiftFold(columns: Columns) async throws {
        try await withTestApp { app in
            _ = try await wrInsertSetup(id: "branch_setup", on: app)
            let student = try await makeTestUser(on: app, username: "branch_student").requireID()
            _ = try await wrInsertSubmission(
                id: "branch_sub", testSetupID: "branch_setup", userID: student, on: app)
            let result = try await wrInsertResult(submissionID: "branch_sub", on: app)
            result.earnedPoints = columns.earned
            result.totalPoints = columns.total
            result.passCount = columns.pass
            result.totalTests = columns.tests
            try await result.save(on: app.db)

            let summaries = try await gradeSummariesBySubmissionID(for: ["branch_sub"], on: app.db)
            let reference = bestGradePercent(of: summaries["branch_sub"] ?? [])

            let byPair = try await bestGradePercentByStudentAndSetup(
                setupIDs: ["branch_setup"], studentIDs: [student], on: app.db)
            #expect(byPair[StudentSetupKey(userID: student, setupID: "branch_setup")] == reference)
            let roster = try await bestGradePercentByStudent(
                setupID: "branch_setup", studentIDs: [student], on: app.db)
            #expect(roster[student] == reference)
            // The dashboard leaves out a best of 0.
            let dashboard = try await studentBestGradePercentBySetup(
                userID: student, setupIDs: ["branch_setup"], on: app.db)
            #expect(dashboard["branch_setup"] == reference.flatMap { $0 > 0 ? $0 : nil })
        }
    }
}
