// Tests/APITests/Grading/StudentSubmissionAggregatesFallbackTests.swift
//
// The Swift fallbacks of the four loaders in `StudentSubmissionAggregates`.
// They run only for a driver without SQL. The test database is Postgres, so
// the tests reach them through `AggregatesNonSQLDatabase`, a wrapper that
// forwards every query but is not an `SQLDatabase`. Each test seeds one set
// of rows and checks the fallback answer, then checks that the SQL path
// gives the same answer over the same rows.

import Core
import Fluent
import FluentKit
import Foundation
import SQLKit
import Testing
import Vapor
import VaporTesting

@testable import APIServer

/// A `Database` that forwards to another one and is not an `SQLDatabase`, so
/// code that checks `db as? any SQLDatabase` takes its non-SQL path.
private struct AggregatesNonSQLDatabase: Database {
    let base: any Database

    var context: DatabaseContext { base.context }
    var inTransaction: Bool { base.inTransaction }

    func execute(
        query: DatabaseQuery, onOutput: @escaping @Sendable (any DatabaseOutput) -> Void
    ) -> EventLoopFuture<Void> {
        base.execute(query: query, onOutput: onOutput)
    }

    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> {
        base.execute(schema: schema)
    }

    func execute(enum: DatabaseEnum) -> EventLoopFuture<Void> {
        base.execute(enum: `enum`)
    }

    func transaction<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        base.transaction { closure(AggregatesNonSQLDatabase(base: $0)) }
    }

    func withConnection<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        base.withConnection { closure(AggregatesNonSQLDatabase(base: $0)) }
    }
}

@Suite(.serialized) final class StudentSubmissionAggregatesFallbackTests {
    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-agg-fallback")
    }

    private func fallbackDB(_ app: Application) -> any Database {
        AggregatesNonSQLDatabase(base: app.db)
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

    /// The by-setup fallback picks the newest `submitted_at`, breaks a tie on
    /// the higher attempt number, counts every student attempt, and ignores
    /// other students, validation runs and setups outside the scope.
    @Test func summaryBySetupFallbackPicksLatestAndMatchesSQL() async throws {
        try await withApp(app) { app in
            #expect(!(fallbackDB(app) is any SQLDatabase))
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

            let fallback = try await studentSubmissionSummaryBySetup(
                userID: me, setupIDs: ["fb_a", "fb_b"], on: fallbackDB(app))

            #expect(fallback.count == 2)
            #expect(fallback["fb_a"]?.latestSubmissionID == "fb_a1")
            #expect(fallback["fb_a"]?.submissionCount == 2)
            #expect(fallback["fb_b"]?.latestSubmissionID == "fb_b2")
            #expect(fallback["fb_b"]?.submissionCount == 2)

            let viaSQL = try await studentSubmissionSummaryBySetup(
                userID: me, setupIDs: ["fb_a", "fb_b"], on: app.db)
            #expect(viaSQL.mapValues(\.latestSubmissionID) == fallback.mapValues(\.latestSubmissionID))
            #expect(viaSQL.mapValues(\.submissionCount) == fallback.mapValues(\.submissionCount))
        }
    }

    /// The by-student fallback picks each student's newest attempt, keeps
    /// that attempt's time, counts the attempts, and ignores other setups,
    /// validation runs and students outside the list.
    @Test func summaryByStudentFallbackPicksLatestAndMatchesSQL() async throws {
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

            let fallback = try await submissionSummaryByStudent(
                setupID: "fb_roster", studentIDs: [alice, bob], on: fallbackDB(app))

            #expect(fallback.count == 2)
            #expect(fallback[alice]?.latestSubmissionID == "fb_r_a1")
            #expect(fallback[alice]?.latestSubmittedAt == Date(timeIntervalSince1970: 5000))
            #expect(fallback[alice]?.submissionCount == 3)
            #expect(fallback[bob]?.latestSubmissionID == "fb_r_b2")
            #expect(fallback[bob]?.latestSubmittedAt == Date(timeIntervalSince1970: 1000))
            #expect(fallback[bob]?.submissionCount == 2)

            let viaSQL = try await submissionSummaryByStudent(
                setupID: "fb_roster", studentIDs: [alice, bob], on: app.db)
            #expect(viaSQL.mapValues(\.latestSubmissionID) == fallback.mapValues(\.latestSubmissionID))
            #expect(viaSQL.mapValues(\.latestSubmittedAt) == fallback.mapValues(\.latestSubmittedAt))
            #expect(viaSQL.mapValues(\.submissionCount) == fallback.mapValues(\.submissionCount))
        }
    }

    // MARK: - Best grade percents

    /// The by-setup fallback keeps the best grade over every result of every
    /// attempt, drops a best of exactly 0, skips a result with no grade
    /// columns, and caps a partial mark at 99.
    @Test func bestBySetupFallbackFoldsLikeTheSQLPath() async throws {
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
            let fallback = try await studentBestGradePercentBySetup(
                userID: me, setupIDs: scope, on: fallbackDB(app))
            #expect(fallback == ["fb_best": 75, "fb_cap": 99])

            let viaSQL = try await studentBestGradePercentBySetup(userID: me, setupIDs: scope, on: app.db)
            #expect(viaSQL == fallback)
        }
    }

    /// The by-student fallback keeps an all-fail 0, takes each student's best
    /// across attempts, and leaves out a student with no gradeable result.
    @Test func bestByStudentFallbackFoldsLikeTheSQLPath() async throws {
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
            let fallback = try await bestGradePercentByStudent(
                setupID: "fb_rbest", studentIDs: students, on: fallbackDB(app))
            #expect(fallback == [alice: 100, bob: 0])

            let viaSQL = try await bestGradePercentByStudent(
                setupID: "fb_rbest", studentIDs: students, on: app.db)
            #expect(viaSQL == fallback)
        }
    }

    /// With no submission in scope, both grade fallbacks stop before they
    /// read results and give an empty map.
    @Test func bestFallbacksAreEmptyWithNoSubmissions() async throws {
        try await withApp(app) { app in
            let (me, _) = try await twoStudents(app)
            try await wrInsertSetup(id: "fb_empty", on: app)

            let bySetup = try await studentBestGradePercentBySetup(
                userID: me, setupIDs: ["fb_empty"], on: fallbackDB(app))
            #expect(bySetup.isEmpty)
            let byStudent = try await bestGradePercentByStudent(
                setupID: "fb_empty", studentIDs: [me], on: fallbackDB(app))
            #expect(byStudent.isEmpty)
            let summary = try await studentSubmissionSummaryBySetup(
                userID: me, setupIDs: ["fb_empty"], on: fallbackDB(app))
            #expect(summary.isEmpty)
            let roster = try await submissionSummaryByStudent(
                setupID: "fb_empty", studentIDs: [me], on: fallbackDB(app))
            #expect(roster.isEmpty)
        }
    }
}
