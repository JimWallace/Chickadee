// Tests/APITests/Grading/GradeSourceDisagreementTests.swift
//
// A browser grade is a participation grade (docs/grading-integrity.md, D8),
// and the best grade still wins, so a forged browser 100 % hides a lower
// native retest. Staff see where the two differ: on the staff history pages
// and on the assignment's roster. The student's own history never shows it,
// and no grade changes.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer
@testable import Core

@Suite(.serialized)
struct GradeSourceDisagreementTests {

    // MARK: - The rule

    private func summary(
        _ source: String?, passed: Int, of total: Int = 4, at seconds: TimeInterval? = 0
    ) -> GradeResultSummary {
        GradeResultSummary(
            resultID: UUID().uuidString, submissionID: "sub", source: source,
            receivedAt: seconds.map { Date(timeIntervalSince1970: $0) },
            earnedPoints: nil, totalPoints: nil, passCount: passed, totalTests: total)
    }

    @Test func oneSourceAloneIsNoDisagreement() {
        #expect(gradeSourceDisagreement(of: [summary("browser", passed: 4)]) == nil)
        #expect(gradeSourceDisagreement(of: [summary("worker", passed: 0)]) == nil)
        #expect(gradeSourceDisagreement(of: [summary(nil, passed: 0), summary("worker", passed: 4)]) == nil)
    }

    @Test func equalGradesAreNoDisagreement() {
        #expect(gradeSourceDisagreement(of: [summary("browser", passed: 3), summary("worker", passed: 3)]) == nil)
    }

    @Test func differentGradesAreReported() {
        let found = gradeSourceDisagreement(of: [summary("browser", passed: 4), summary("worker", passed: 1)])
        #expect(found == GradeSourceDisagreement(browserPercent: 100, nativePercent: 25))
    }

    @Test func aLegacyRowWithNoSourceIsNative() {
        let found = gradeSourceDisagreement(of: [summary("browser", passed: 4), summary(nil, passed: 2)])
        #expect(found == GradeSourceDisagreement(browserPercent: 100, nativePercent: 50))
    }

    /// The best browser grade is the one that counts, and the newest native
    /// result is the latest retest; a row with no receive time is the oldest.
    @Test func theBestBrowserGradeMeetsTheNewestNativeGrade() {
        let results = [
            summary("browser", passed: 2), summary("browser", passed: 4),
            summary("worker", passed: 4, at: 10), summary("worker", passed: 1, at: 20),
            summary("worker", passed: 3, at: nil),
        ]
        #expect(gradeSourceDisagreement(of: results) == GradeSourceDisagreement(browserPercent: 100, nativePercent: 25))

        let retestAgrees = [
            summary("browser", passed: 4), summary("worker", passed: 1, at: 10), summary("worker", passed: 4, at: 20),
        ]
        #expect(gradeSourceDisagreement(of: retestAgrees) == nil, "a later retest that agrees clears it")
    }

    // MARK: - The pages

    private struct Fixture {
        let instructorCookie: String
        let studentUsername: String
        let studentID: UUID
        let historyPath: String
        let rosterPath: String
    }

    /// One student with two submissions: `sub_agree` graded the same by both
    /// sources, and `sub_differs` graded 100 % in the browser and 0 % natively.
    private func fixture(on app: Application) async throws -> Fixture {
        let cookie = try await arLoginAsInstructor(on: app)
        let student = try await arInsertStudent(username: "src_dana", displayName: "Dana Source", on: app)
        try await arEnrollStudentInTestCourse(student, on: app)
        _ = try await arInsertSetup(id: "src_setup", on: app)
        let assignment = try await arInsertAssignment(
            testSetupID: "src_setup", title: "Source Lab", isOpen: true, on: app)
        let studentID = try student.requireID()
        for (id, attempt) in [("sub_agree", 1), ("sub_differs", 2)] {
            _ = try await arInsertSubmission(
                id: id, testSetupID: "src_setup", userID: studentID, attemptNumber: attempt, on: app)
        }
        let pass = [wrMakeOutcome(name: "t1", status: .pass)]
        let fail = [wrMakeOutcome(name: "t1", status: .fail)]
        try await wrInsertResult(submissionID: "sub_agree", outcomes: pass, source: "browser", on: app)
        try await wrInsertResult(submissionID: "sub_agree", outcomes: pass, source: "worker", on: app)
        try await wrInsertResult(submissionID: "sub_differs", outcomes: pass, source: "browser", on: app)
        try await wrInsertResult(submissionID: "sub_differs", outcomes: fail, source: "worker", on: app)
        return Fixture(
            instructorCookie: cookie, studentUsername: student.username, studentID: studentID,
            historyPath: "/instructor/\(assignment.publicID)/students/\(studentID.uuidString)/history",
            rosterPath: "/instructor/\(assignment.publicID)/submissions")
    }

    @Test func theRosterQueryFindsOnlyTheStudentWhoseGradesDiffer() async throws {
        try await withAssignmentRoutesApp { app in
            let page = try await fixture(on: app)
            let other = try await arInsertStudent(username: "src_eli", on: app)
            let otherID = try other.requireID()
            _ = try await arInsertSubmission(id: "sub_other", testSetupID: "src_setup", userID: otherID, on: app)
            try await wrInsertResult(
                submissionID: "sub_other", outcomes: [wrMakeOutcome(name: "t1", status: .pass)],
                source: "browser", on: app)

            // Both sources, but the native result has no grade (an empty
            // collection): the SQL admits it, and the rule must not flag it.
            let third = try await arInsertStudent(username: "src_fay", on: app)
            let thirdID = try third.requireID()
            _ = try await arInsertSubmission(id: "sub_ungraded", testSetupID: "src_setup", userID: thirdID, on: app)
            try await wrInsertResult(
                submissionID: "sub_ungraded", outcomes: [wrMakeOutcome(name: "t1", status: .pass)],
                source: "browser", on: app)
            try await wrInsertResult(submissionID: "sub_ungraded", outcomes: [], source: "worker", on: app)

            let found = try await studentsWithGradeSourceDisagreement(
                setupID: "src_setup", studentIDs: [page.studentID, otherID, thirdID], on: app.db)
            #expect(found == [page.studentID])
        }
    }

    @Test func staffSeeBothGradesOnTheHistoryAndAFlagOnTheRoster() async throws {
        try await withAssignmentRoutesApp { app in
            let page = try await fixture(on: app)

            let history = try await getHTML(page.historyPath, cookie: page.instructorCookie, on: app)
            #expect(history.contains("Browser 100% · native 0%"))
            #expect(history.components(separatedBy: "Browser 100% · native").count == 2, "only sub_differs")

            let roster = try await getHTML(page.rosterPath, cookie: page.instructorCookie, on: app)
            #expect(roster.contains("Browser and native differ"))
            // The best grade still counts: the flag changes no grade.
            #expect(roster.contains("100%"))
        }
    }

    @Test func theStudentsOwnHistoryDoesNotShowIt() async throws {
        try await withAssignmentRoutesApp { app in
            let page = try await fixture(on: app)
            let cookie = try await loginUser(
                username: page.studentUsername, password: "testpassword", role: "student", on: app)
            let own = try await getHTML("/testsetups/src_setup/history", cookie: cookie, on: app)
            #expect(own.contains("100%"))
            #expect(!own.contains("native"))
        }
    }
}
