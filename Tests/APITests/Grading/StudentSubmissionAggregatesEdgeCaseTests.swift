// Tests/APITests/Grading/StudentSubmissionAggregatesEdgeCaseTests.swift
//
// Edge cases of the four SQL loaders in `StudentSubmissionAggregates` that
// `StudentSubmissionAggregatesTests` does not pin: newest time beats a higher
// attempt, a tie on time goes to the higher attempt, a partial mark of 199.5
// of 200 reads 99, and an empty scope gives an empty map. These cases came
// from the tests of the removed non-SQL fallbacks (#3165); they now run on
// the SQL path only.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class StudentSubmissionAggregatesEdgeCaseTests {
    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-agg-edge")
    }

    /// Two students, "student1" and "student2".
    private func twoStudents(_ app: Application) async throws -> (UUID, UUID) {
        _ = try await loginUser(username: "student1", password: "pass", role: "student", on: app)
        _ = try await loginUser(username: "student2", password: "pass", role: "student", on: app)
        let first = try await wrStudentUser(on: app).requireID()
        let second = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "student2").first()
        ).requireID()
        return (first, second)
    }

    /// A student submission with a fixed `submitted_at`. The create
    /// timestamp is set on save, so the test writes its own time after.
    private func submission(
        _ id: String, setup: String, user: UUID, attempt: Int, at seconds: Double,
        kind: String = APISubmission.Kind.student, on app: Application
    ) async throws {
        let sub = APISubmission(
            id: id, testSetupID: setup, zipPath: app.submissionsDirectory + "\(id).py",
            attemptNumber: attempt, userID: user, kind: kind)
        try await sub.save(on: app.db)
        sub.submittedAt = Date(timeIntervalSince1970: seconds)
        try await sub.save(on: app.db)
    }

    private func outcomes(pass: Int, fail: Int) -> [TestOutcome] {
        (0..<pass).map { wrMakeOutcome(name: "p\($0)", status: .pass) }
            + (0..<fail).map { wrMakeOutcome(name: "f\($0)", status: .fail) }
    }

    // MARK: - Submission summaries

    /// The by-setup summary picks the newest `submitted_at`, breaks a tie on
    /// the higher attempt number, counts every student attempt, and ignores
    /// other students, validation runs and setups outside the scope.
    @Test func summaryBySetupPrefersTimeThenAttempt() async throws {
        try await withApp(app) { app in
            let (me, other) = try await twoStudents(app)
            for setup in ["fb_a", "fb_b", "fb_out"] { try await wrInsertSetup(id: setup, on: app) }
            // fb_a: attempt 1 is newer than attempt 2, so time wins over attempt.
            try await submission("fb_a1", setup: "fb_a", user: me, attempt: 1, at: 2000, on: app)
            try await submission("fb_a2", setup: "fb_a", user: me, attempt: 2, at: 1000, on: app)
            // fb_b: two attempts at the same time; the higher attempt wins.
            try await submission("fb_b1", setup: "fb_b", user: me, attempt: 1, at: 3000, on: app)
            try await submission("fb_b2", setup: "fb_b", user: me, attempt: 2, at: 3000, on: app)
            // Noise: newer rows the summary must ignore.
            try await submission("fb_other", setup: "fb_a", user: other, attempt: 1, at: 9000, on: app)
            try await submission(
                "fb_val", setup: "fb_a", user: me, attempt: 3, at: 9000,
                kind: APISubmission.Kind.validation, on: app)
            try await submission("fb_out1", setup: "fb_out", user: me, attempt: 1, at: 9000, on: app)

            let loaded = try await studentSubmissionSummaryBySetup(
                userID: me, setupIDs: ["fb_a", "fb_b"], on: app.db)

            #expect(loaded.count == 2)
            #expect(loaded["fb_a"]?.latestSubmissionID == "fb_a1")
            #expect(loaded["fb_a"]?.submissionCount == 2)
            #expect(loaded["fb_b"]?.latestSubmissionID == "fb_b2")
            #expect(loaded["fb_b"]?.submissionCount == 2)
        }
    }

    /// The by-student summary picks each student's newest attempt, keeps
    /// that attempt's time, counts the attempts, and ignores other setups,
    /// validation runs and students outside the list.
    @Test func summaryByStudentPrefersTimeThenAttempt() async throws {
        try await withApp(app) { app in
            let (alice, bob) = try await twoStudents(app)
            _ = try await loginUser(username: "student3", password: "pass", role: "student", on: app)
            let carol = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "student3").first()
            ).requireID()
            try await wrInsertSetup(id: "fb_roster", on: app)
            try await wrInsertSetup(id: "fb_roster_other", on: app)
            try await submission("fb_r_a1", setup: "fb_roster", user: alice, attempt: 1, at: 5000, on: app)
            try await submission("fb_r_a2", setup: "fb_roster", user: alice, attempt: 2, at: 4000, on: app)
            try await submission("fb_r_a3", setup: "fb_roster", user: alice, attempt: 3, at: 4500, on: app)
            try await submission("fb_r_b1", setup: "fb_roster", user: bob, attempt: 1, at: 1000, on: app)
            try await submission("fb_r_b2", setup: "fb_roster", user: bob, attempt: 2, at: 1000, on: app)
            // Noise: another setup, a validation run, a student not asked for.
            try await submission(
                "fb_r_x", setup: "fb_roster_other", user: alice, attempt: 4, at: 9000, on: app)
            try await submission(
                "fb_r_val", setup: "fb_roster", user: bob, attempt: 3, at: 9000,
                kind: APISubmission.Kind.validation, on: app)
            try await submission("fb_r_c1", setup: "fb_roster", user: carol, attempt: 1, at: 9000, on: app)

            let loaded = try await submissionSummaryByStudent(
                setupID: "fb_roster", studentIDs: [alice, bob], on: app.db)

            #expect(loaded.count == 2)
            #expect(loaded[alice]?.latestSubmissionID == "fb_r_a1")
            #expect(loaded[alice]?.latestSubmittedAt == Date(timeIntervalSince1970: 5000))
            #expect(loaded[alice]?.submissionCount == 3)
            #expect(loaded[bob]?.latestSubmissionID == "fb_r_b2")
            #expect(loaded[bob]?.latestSubmittedAt == Date(timeIntervalSince1970: 1000))
            #expect(loaded[bob]?.submissionCount == 2)
        }
    }

    // MARK: - Best grade percents

    /// The by-setup best grade keeps the best grade over every result of every
    /// attempt, drops a best of exactly 0, skips a result with no grade
    /// columns, and caps a partial mark at 99.
    @Test func bestBySetupCapsAPartialMarkAt99() async throws {
        try await withApp(app) { app in
            let (me, other) = try await twoStudents(app)
            for setup in ["fb_best", "fb_zero", "fb_nograde", "fb_cap", "fb_none"] {
                try await wrInsertSetup(id: setup, on: app)
            }
            // fb_best: 1/4 then 3/4 on attempt 1, 2/4 on attempt 2. Best is 75.
            try await submission("fb_best1", setup: "fb_best", user: me, attempt: 1, at: 1000, on: app)
            try await wrInsertResult(submissionID: "fb_best1", outcomes: outcomes(pass: 1, fail: 3), on: app)
            try await wrInsertResult(
                submissionID: "fb_best1", outcomes: outcomes(pass: 3, fail: 1), source: "browser", on: app)
            try await submission("fb_best2", setup: "fb_best", user: me, attempt: 2, at: 2000, on: app)
            try await wrInsertResult(submissionID: "fb_best2", outcomes: outcomes(pass: 2, fail: 2), on: app)
            // Another student's 4/4 on the same setup must not count.
            try await submission("fb_best_o", setup: "fb_best", user: other, attempt: 1, at: 1000, on: app)
            try await wrInsertResult(submissionID: "fb_best_o", outcomes: outcomes(pass: 4, fail: 0), on: app)
            // fb_zero: an all-fail result. The dashboard shows no grade.
            try await submission("fb_zero1", setup: "fb_zero", user: me, attempt: 1, at: 1000, on: app)
            try await wrInsertResult(submissionID: "fb_zero1", outcomes: outcomes(pass: 0, fail: 2), on: app)
            // fb_nograde: a result with no parseable grade.
            try await submission("fb_ng1", setup: "fb_nograde", user: me, attempt: 1, at: 1000, on: app)
            try await APIResult(id: "fb_res_ng", submissionID: "fb_ng1", source: "worker")
                .saveWithCollection(json: "not json", on: app.db)
            // fb_cap: 199.5 of 200 points rounds to 100, but a partial mark reads 99.
            try await submission("fb_cap1", setup: "fb_cap", user: me, attempt: 1, at: 1000, on: app)
            try await APIResult(id: "fb_res_cap", submissionID: "fb_cap1", source: "worker")
                .saveWithCollection(
                    json:
                        #"{"submissionID":"fb_cap1","earnedPoints":199.5,"totalPoints":200,"passCount":3,"totalTests":4}"#,
                    on: app.db)
            // fb_none: no submission at all.

            let scope = ["fb_best", "fb_zero", "fb_nograde", "fb_cap", "fb_none"]
            let loaded = try await studentBestGradePercentBySetup(
                userID: me, setupIDs: scope, on: app.db)
            #expect(loaded == ["fb_best": 75, "fb_cap": 99])
        }
    }

    /// The by-student best grade keeps an all-fail 0, takes each student's best
    /// across attempts, and leaves out a student with no gradeable result.
    @Test func bestByStudentKeepsZeroAndSkipsNoResult() async throws {
        try await withApp(app) { app in
            let (alice, bob) = try await twoStudents(app)
            _ = try await loginUser(username: "student3", password: "pass", role: "student", on: app)
            let carol = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "student3").first()
            ).requireID()
            try await wrInsertSetup(id: "fb_rbest", on: app)
            try await wrInsertSetup(id: "fb_rbest_other", on: app)
            // Alice: 1/2 then 2/2 across two attempts. Best is 100.
            try await submission("fb_rb_a1", setup: "fb_rbest", user: alice, attempt: 1, at: 1000, on: app)
            try await wrInsertResult(submissionID: "fb_rb_a1", outcomes: outcomes(pass: 1, fail: 1), on: app)
            try await submission("fb_rb_a2", setup: "fb_rbest", user: alice, attempt: 2, at: 2000, on: app)
            try await wrInsertResult(submissionID: "fb_rb_a2", outcomes: outcomes(pass: 2, fail: 0), on: app)
            // Bob: all fail. The roster shows 0.
            try await submission("fb_rb_b1", setup: "fb_rbest", user: bob, attempt: 1, at: 1000, on: app)
            try await wrInsertResult(submissionID: "fb_rb_b1", outcomes: outcomes(pass: 0, fail: 3), on: app)
            // Bob's 3/3 on another setup must not count here.
            try await submission(
                "fb_rb_bx", setup: "fb_rbest_other", user: bob, attempt: 1, at: 1000, on: app)
            try await wrInsertResult(submissionID: "fb_rb_bx", outcomes: outcomes(pass: 3, fail: 0), on: app)
            // Carol: a submission with no result. She is absent.
            try await submission("fb_rb_c1", setup: "fb_rbest", user: carol, attempt: 1, at: 1000, on: app)

            let students = [alice, bob, carol]
            let loaded = try await bestGradePercentByStudent(
                setupID: "fb_rbest", studentIDs: students, on: app.db)
            #expect(loaded == [alice: 100, bob: 0])
        }
    }

    /// With no submission in scope, all four loaders give an empty map.
    @Test func loadersAreEmptyWithNoSubmissions() async throws {
        try await withApp(app) { app in
            let (me, _) = try await twoStudents(app)
            try await wrInsertSetup(id: "fb_empty", on: app)

            let bySetup = try await studentBestGradePercentBySetup(
                userID: me, setupIDs: ["fb_empty"], on: app.db)
            #expect(bySetup.isEmpty)
            let byStudent = try await bestGradePercentByStudent(
                setupID: "fb_empty", studentIDs: [me], on: app.db)
            #expect(byStudent.isEmpty)
            let summary = try await studentSubmissionSummaryBySetup(
                userID: me, setupIDs: ["fb_empty"], on: app.db)
            #expect(summary.isEmpty)
            let roster = try await submissionSummaryByStudent(
                setupID: "fb_empty", studentIDs: [me], on: app.db)
            #expect(roster.isEmpty)
        }
    }
}
