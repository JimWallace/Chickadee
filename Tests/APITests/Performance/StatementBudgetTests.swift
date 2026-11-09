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
// What is counted: the statements that the route sends on `req.db`. The test
// app keeps sessions in memory and does not install the request-metrics
// middleware, so the session lookup and the metrics insert that production
// adds to every request are not in these numbers. The per-page counts in
// docs/database-performance.md come from pg_stat_statements on a production
// build and include them.

import Fluent
import Foundation
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
        .studentDashboard: 0,
        .studentSubmission: 0,
        .studentHistory: 0,
        .statusPoll: 0,
        .staffSubmission: 0,
        .instructorSubmissions: 0,
        .gradesCSV: 0,
        .instructorList: 0,
        .adminDashboard: 0,
        .runnerPollIdle: 0,
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
    struct Scale: Sendable {
        let students: Int
        let attempts: Int

        static let small = Scale(students: 2, attempts: 1)
        static let large = Scale(students: 8, attempts: 3)
    }

    @Test func eachPageSendsItsBudgetedStatements() async throws {
        let counts = try await measureEveryPage(at: .small)
        for page in Page.allCases {
            let budget = try #require(Self.budgets[page], "\(page.rawValue) has no budget")
            let count = try #require(counts[page])
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
                few == many,
                "\(page.rawValue): \(few) statements for \(Scale.small.students) students, \(many) for \(Scale.large.students). A count that grows with the data is a query per row."
            )
        }
    }

    // MARK: - Measuring

    private static let workerSecret = "statement-budget-secret"

    /// Builds a course at `scale` in a fresh app and measures each page once.
    private func measureEveryPage(at scale: Scale) async throws -> [Page: Int] {
        var counts: [Page: Int] = [:]
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
                counts[page] = statements.count
            }
        }
        return counts
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
