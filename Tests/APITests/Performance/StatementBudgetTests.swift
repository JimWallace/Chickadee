// Tests/APITests/Performance/StatementBudgetTests.swift
//
// The number of SQL statements each hot page sends, held at a baseline
// (docs/performance-program.md, "Ratchets to add"). A statement count does
// not depend on the machine, so it can gate a pull request where a latency
// cannot.
//
// Two checks per page:
//
// - **The count equals its budget.** A change that adds a statement fails
//   here. A change that removes one fails too, with the new count, so the
//   budget is lowered in the same pull request and cannot creep back up.
// - **The count does not grow with the data.** Each page is measured on a
//   small course and on a larger one. A count that differs is a query per
//   row: an N+1.
//
// What is counted: every statement that the route sends on `req.db`, with a
// transaction's BEGIN and COMMIT counted as two, as pg_stat_statements counts
// them. Three things are not counted:
//
// - A statement sent on `app.db` (or `req.application.db`) during the
//   request. It logs to the app's logger, not the request's. A route that
//   moves a query there escapes its budget, so keep request work on `req.db`.
// - A statement sent after the response, from a detached task. The counts
//   are stable run to run today; a budget that flickers means such work
//   started reading the database.
// - The session lookup and the request-metrics insert that production adds
//   to each request. The test app keeps sessions in memory and does not
//   install the metrics middleware. So a page here counts one or two fewer
//   statements than the pg_stat_statements counts in
//   docs/database-performance.md. The runner poll is signed, not session
//   based, and matches them.

import Fluent
import Foundation
import NIOCore
import NIOFoundationCompat
import Testing
import Vapor
import VaporTesting

@testable import APIServer
@testable import Core

@Suite(.serialized, .timeLimit(.minutes(5)))
struct StatementBudgetTests {

    /// The pages measured, and the statements each may send.
    ///
    /// When a count goes down, lower its budget here in the same pull request.
    /// When a count must go up, raise it with the reason in the pull request.
    static let budgets: [Page: Int] = [
        .studentDashboard: 20,
        .studentSubmission: 15,
        .studentHistory: 8,
        .statusPoll: 2,
        .staffSubmission: 13,
        .instructorSubmissions: 18,
        .gradesCSV: 14,
        .instructorList: 13,
        .adminDashboard: 10,
        .runnerPollIdle: 3,
    ]

    enum Page: String, CaseIterable, Sendable {
        case studentDashboard = "student dashboard"
        case studentSubmission = "student submission"
        case studentHistory = "student history"
        case statusPoll = "status poll"
        case staffSubmission = "staff view of a submission"
        case instructorSubmissions = "instructor assignment submissions"
        case gradesCSV = "grades CSV"
        case instructorList = "instructor assignment list"
        case adminDashboard = "admin dashboard"
        case runnerPollIdle = "idle runner poll"
    }

    /// The size of the course a measurement runs on.
    ///
    /// Both scales have at least two attempts per student. A page may skip a
    /// query when no student has a second attempt (the student dashboard's
    /// prior-attempt lookup does), and a scale that took that branch would read
    /// as a query that grows with the data.
    struct Scale: Sendable {
        let students: Int
        let attempts: Int

        static let small = Scale(students: 2, attempts: 2)
        static let large = Scale(students: 8, attempts: 3)
    }

    @Test func eachPageSendsItsBudgetedStatements() async throws {
        let statements = try await measureEveryPage(at: .small)
        for page in Page.allCases {
            let budget = try #require(Self.budgets[page], "\(page.rawValue) has no budget")
            let count = try #require(statements[page]).count
            #expect(
                count == budget,
                "\(page.rawValue): \(count) statements, budget \(budget). \(count < budget ? "Lower the budget to \(count)." : "Find the added statement.")"
            )
        }
    }

    @Test func noPageSendsMoreStatementsForMoreData() async throws {
        let small = try await measureEveryPage(at: .small)
        let large = try await measureEveryPage(at: .large)
        for page in Page.allCases {
            let few = try #require(small[page])
            let many = try #require(large[page])
            #expect(
                few.count == many.count,
                "\(page.rawValue): \(few.count) statements for \(Scale.small.students) students, \(many.count) for \(Scale.large.students). A count that grows with the data is a query per row. Only in the larger course: \(Self.extra(in: many, over: few))"
            )
        }
    }

    /// The statements in `larger` beyond those in `smaller`, counted as a
    /// multiset, so a statement that runs once more shows once.
    static func extra(in larger: [String], over smaller: [String]) -> [String] {
        var remaining = Dictionary(smaller.map { ($0, 1) }, uniquingKeysWith: +)
        var extra: [String] = []
        for statement in larger {
            if let left = remaining[statement], left > 0 {
                remaining[statement] = left - 1
            } else {
                extra.append(statement)
            }
        }
        return extra
    }

    // MARK: - Measuring

    private static let workerSecret = "statement-budget-secret"

    /// Builds a course at `scale` in a fresh app and measures each page once.
    private func measureEveryPage(at scale: Scale) async throws -> [Page: [String]] {
        var recorded: [Page: [String]] = [:]
        try await withTestApp(prefix: "chickadee-statements") { app in
            let recorder = StatementRecorder()
            app.middleware.use(StatementCountingMiddleware(recorder: recorder), at: .beginning)
            await app.workerSecretStore.setRuntimeOverride(Self.workerSecret)
            let course = try await StatementBudgetCourse.build(at: scale, on: app)

            for page in Page.allCases {
                // Twice: the first request may warm a cache that the second
                // reads, and the steady state is what a page costs.
                _ = try await send(page, course: course, on: app)
                recorder.arm()
                let response = try await send(page, course: course, on: app)
                let statements = recorder.disarm()
                #expect(
                    response.status.code < 400, "\(page.rawValue) answered \(response.status.code)")
                recorded[page] = statements
            }
        }
        return recorded
    }

    private func send(
        _ page: Page, course: StatementBudgetCourse, on app: Application
    ) async throws
        -> TestResponse
    {
        switch page {
        case .studentDashboard:
            return try await getResponse("/", cookie: course.studentCookie, on: app)
        case .studentSubmission:
            return try await getResponse(
                "/submissions/\(course.submissionID)", cookie: course.studentCookie, on: app)
        case .studentHistory:
            return try await getResponse(
                "/testsetups/\(course.setupID)/history", cookie: course.studentCookie, on: app)
        case .statusPoll:
            return try await getResponse(
                "/api/v1/submissions/\(course.submissionID)", cookie: course.studentCookie, on: app)
        case .staffSubmission:
            return try await getResponse(
                "/submissions/\(course.submissionID)", cookie: course.instructorCookie, on: app)
        case .instructorSubmissions:
            return try await getResponse(
                "/instructor/\(course.assignmentID)/submissions", cookie: course.instructorCookie, on: app)
        case .gradesCSV:
            return try await getResponse("/instructor/grades.csv", cookie: course.instructorCookie, on: app)
        case .instructorList:
            return try await getResponse("/instructor", cookie: course.instructorCookie, on: app)
        case .adminDashboard:
            return try await getResponse("/admin", cookie: course.adminCookie, on: app)
        case .runnerPollIdle:
            let path = "/api/v1/worker/request"
            let payload = WorkerActivityPayload(
                workerID: "statement-budget-runner", hostname: "statement-budget.local",
                runnerVersion: "statement-budget/1.0", maxConcurrentJobs: 1, activeJobs: 0, profile: nil)
            let body = ByteBuffer(data: try JSONEncoder().encode(payload))
            let headers = workerHMACHeaders(
                method: .POST, path: path, body: body, workerSecret: Self.workerSecret)
            return try await app.asyncSendRequest(.POST, path, headers: headers, body: body)
        }
    }
}

/// One course at a given scale: an instructor, an admin, `students` students
/// with `attempts` graded submissions each on one assignment. The first
/// student is signed in; the others exist only as data.
struct StatementBudgetCourse {
    let studentCookie: String
    let instructorCookie: String
    let adminCookie: String
    let setupID: String
    let assignmentID: String
    let submissionID: String

    static func build(at scale: StatementBudgetTests.Scale, on app: Application) async throws -> Self {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let instructorCookie = try await loginAsCourseInstructor(username: "budget_instructor", on: app)
        let adminCookie = try await loginAsAdmin("budget_admin", on: app)
        let studentCookie = try await loginAsStudent("budget_student", on: app)
        try await enrollInTestCourse(username: "budget_student", role: .student, on: app)

        let setupID = "budget_setup"
        try await makeTestSetup(on: app, id: setupID, courseID: courseID)
        let assignment = try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)

        let signedIn = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "budget_student").first())
        var studentIDs = [try signedIn.requireID()]
        for index in 1..<scale.students {
            let student = try await makeTestStudent(on: app, username: "budget_student_\(index)")
            let studentID = try student.requireID()
            try await makeTestEnrollment(on: app, userID: studentID, courseID: courseID)
            studentIDs.append(studentID)
        }

        var firstSubmissionID: String?
        for (studentIndex, studentID) in studentIDs.enumerated() {
            for attempt in 1...scale.attempts {
                let id = "budget_sub_\(studentIndex)_\(attempt)"
                let submission = try await makeTestSubmission(
                    on: app, id: id, setupID: setupID, userID: studentID)
                submission.attemptNumber = attempt
                try await submission.save(on: app.db)
                try await makeTestResult(on: app, submissionID: id)
                if studentIndex == 0, firstSubmissionID == nil { firstSubmissionID = id }
            }
        }

        return Self(
            studentCookie: studentCookie,
            instructorCookie: instructorCookie,
            adminCookie: adminCookie,
            setupID: setupID,
            assignmentID: assignment.publicID,
            submissionID: try #require(firstSubmissionID)
        )
    }
}
