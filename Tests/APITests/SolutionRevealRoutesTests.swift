// Tests/APITests/SolutionRevealRoutesTests.swift
//
// The student-facing solution reveal over the web surface:
//
//   - GET /testsetups/:id/solution/download refuses a student before their
//     reveal moment (deadline not passed, or a slip-day claim still
//     reachable, or the policy off) and streams the solution file after it
//   - course staff pass the download gate unconditionally
//   - GET /testsetups/:id/notebook/source?file=solution — the endpoint the
//     editor fetches — obeys the same gate
//   - the dashboard row offers the "View the solution" action exactly when
//     the gate holds

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer
@testable import Core

@Suite struct SolutionRevealRoutesTests {

    private let solutionCellSource = "answer = 42"

    /// Seeds the enrolled student, the CS101 course (slip days optional), an
    /// assignment with the reveal policy on, and a linked validation
    /// submission whose file on disk is a minimal notebook — the solution the
    /// routes should serve.
    @discardableResult
    private func seedRevealFixture(
        app: Application,
        setupID: String,
        dueAgo: TimeInterval,
        solutionVisibility: SolutionVisibility = .afterDue,
        slipDaysEnabled: Bool = false
    ) async throws -> (cookie: String, student: APIUser, assignment: APIAssignment) {
        let cookie = try await wrLoginAsStudent(on: app)
        let student = try await wrStudentUser(on: app)
        try await wrEnrollUser(student, on: app)
        let course = try await wrMakeCourse(on: app)
        course.slipDaysEnabled = slipDaysEnabled
        course.slipDaysPerStudent = 2
        course.slipDayExtensionHours = 24
        try await course.save(on: app.db)
        try await wrInsertSetup(id: setupID, on: app)
        let assignment = try await wrInsertAssignment(
            testSetupID: setupID, title: "Reveal Lab", isOpen: false,
            dueAt: Date(timeIntervalSinceNow: -dueAgo), on: app)
        assignment.solutionVisibility = solutionVisibility
        assignment.validationSubmissionID = try await seedSolutionSubmission(
            app: app, setupID: setupID, userID: student.requireID())
        try await assignment.save(on: app.db)
        return (cookie, student, assignment)
    }

    /// Writes a minimal solution notebook to disk and records it as a
    /// validation submission, returning its ID for
    /// `assignment.validationSubmissionID`.
    private func seedSolutionSubmission(
        app: Application, setupID: String, userID: UUID
    ) async throws -> String {
        let notebookJSON = """
            {"cells":[{"cell_type":"code","metadata":{},"outputs":[],"source":["\(solutionCellSource)"]}],"metadata":{},"nbformat":4,"nbformat_minor":5}
            """
        let path = app.submissionsDirectory + "solution_\(setupID).ipynb"
        try notebookJSON.write(toFile: path, atomically: true, encoding: .utf8)
        let sub = APISubmission(
            id: "val_\(setupID)",
            testSetupID: setupID,
            zipPath: path,
            attemptNumber: 1,
            status: "complete",
            filename: "solution.ipynb",
            userID: userID,
            kind: APISubmission.Kind.validation
        )
        try await sub.save(on: app.db)
        return "val_\(setupID)"
    }

    private func getStatusAndBody(
        app: Application, path: String, cookie: String
    ) async throws -> (status: HTTPStatus, body: String) {
        var status = HTTPStatus.imATeapot
        var body = ""
        try await app.asyncTest(
            .GET, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                status = res.status
                body = res.body.string
            })
        return (status, body)
    }

    // MARK: - GET /testsetups/:id/solution/download

    @Test func downloadRefusedBeforeTheDeadline() async throws {
        try await withWebRoutesApp { app in
            let (cookie, _, _) = try await seedRevealFixture(
                app: app, setupID: "setup_rv1", dueAgo: -3600)
            let (status, _) = try await getStatusAndBody(
                app: app, path: "/testsetups/setup_rv1/solution/download", cookie: cookie)
            #expect(status == .forbidden)
        }
    }

    @Test func downloadRefusedWhileASlipDayClaimIsReachable() async throws {
        try await withWebRoutesApp { app in
            let (cookie, _, _) = try await seedRevealFixture(
                app: app, setupID: "setup_rv2", dueAgo: 3600, slipDaysEnabled: true)
            let (status, _) = try await getStatusAndBody(
                app: app, path: "/testsetups/setup_rv2/solution/download", cookie: cookie)
            #expect(status == .forbidden)
        }
    }

    @Test func downloadRefusedWhenPolicyHidden() async throws {
        try await withWebRoutesApp { app in
            let (cookie, _, _) = try await seedRevealFixture(
                app: app, setupID: "setup_rv3", dueAgo: 3600, solutionVisibility: .hidden)
            let (status, _) = try await getStatusAndBody(
                app: app, path: "/testsetups/setup_rv3/solution/download", cookie: cookie)
            #expect(status == .forbidden)
        }
    }

    @Test func downloadStreamsTheSolutionAfterTheRevealMoment() async throws {
        try await withWebRoutesApp { app in
            let (cookie, _, _) = try await seedRevealFixture(
                app: app, setupID: "setup_rv4", dueAgo: 3600)
            let (status, body) = try await getStatusAndBody(
                app: app, path: "/testsetups/setup_rv4/solution/download", cookie: cookie)
            #expect(status == .ok)
            #expect(body.contains(solutionCellSource))
        }
    }

    @Test func downloadStreamsOnceTheSlipClaimWindowLapses() async throws {
        try await withWebRoutesApp { app in
            let (cookie, _, _) = try await seedRevealFixture(
                app: app, setupID: "setup_rv5", dueAgo: 25 * 3600, slipDaysEnabled: true)
            let (status, body) = try await getStatusAndBody(
                app: app, path: "/testsetups/setup_rv5/solution/download", cookie: cookie)
            #expect(status == .ok)
            #expect(body.contains(solutionCellSource))
        }
    }

    @Test func staffDownloadIgnoresTheRevealGate() async throws {
        try await withWebRoutesApp { app in
            _ = try await seedRevealFixture(
                app: app, setupID: "setup_rv6", dueAgo: -3600, solutionVisibility: .hidden)
            let staffCookie = try await wrLoginAsInstructor(on: app)
            let staff = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(staff, on: app)
            let (status, body) = try await getStatusAndBody(
                app: app, path: "/testsetups/setup_rv6/solution/download", cookie: staffCookie)
            #expect(status == .ok)
            #expect(body.contains(solutionCellSource))
        }
    }

    // MARK: - GET /testsetups/:id/notebook/source?file=solution

    @Test func notebookSourceSolutionObeysTheGate() async throws {
        try await withWebRoutesApp { app in
            let (cookie, student, assignment) = try await seedRevealFixture(
                app: app, setupID: "setup_rv7", dueAgo: 3600)
            // The source endpoint's closed-assignment gate wants prior
            // engagement; the page records it on first visit, so mirror that.
            try await AssignmentParticipationStore.recordFirstAccess(
                userID: student.requireID(), assignmentID: assignment.requireID(), on: app.db)

            let (okStatus, body) = try await getStatusAndBody(
                app: app,
                path: "/testsetups/setup_rv7/notebook/source?file=solution",
                cookie: cookie)
            #expect(okStatus == .ok)
            #expect(body.contains(solutionCellSource))

            // Re-hide the policy: the same fetch must refuse again.
            assignment.solutionVisibility = .hidden
            try await assignment.save(on: app.db)
            let (deniedStatus, _) = try await getStatusAndBody(
                app: app,
                path: "/testsetups/setup_rv7/notebook/source?file=solution",
                cookie: cookie)
            #expect(deniedStatus == .forbidden)
        }
    }

    // MARK: - Dashboard action

    @Test func dashboardOffersTheSolutionActionExactlyWhenRevealed() async throws {
        try await withWebRoutesApp { app in
            let (cookie, _, assignment) = try await seedRevealFixture(
                app: app, setupID: "setup_rv8", dueAgo: 3600)
            let (status, html) = try await getStatusAndBody(app: app, path: "/", cookie: cookie)
            #expect(status == .ok)
            #expect(html.contains("title=\"Solution\""))
            #expect(html.contains("/testsetups/setup_rv8/notebook?file=solution"))

            assignment.solutionVisibility = .hidden
            try await assignment.save(on: app.db)
            let (_, hiddenHTML) = try await getStatusAndBody(app: app, path: "/", cookie: cookie)
            #expect(!hiddenHTML.contains("title=\"Solution\""))
            #expect(!hiddenHTML.contains("/testsetups/setup_rv8/notebook?file=solution"))
        }
    }
}
