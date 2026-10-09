// Tests/APITests/AIFeedbackWebRoutesTests.swift
//
// The web half of AI-assisted feedback (docs/ai-assisted-feedback.md), end to
// end:
//
//   - only an admin sets the course gate;
//   - an instructor cannot set the assignment gate while the course gate is off;
//   - a draft is invisible to the student until course staff release it, and a
//     discarded one disappears again;
//   - the upload page tells the student before they submit.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer
@testable import Core

@Suite(.serialized) struct AIFeedbackWebRoutesTests {

    private struct Seed {
        let instructorCookie: String
        let studentCookie: String
        let assignment: APIAssignment
        let course: APICourse
    }

    /// CS101 with instructor1 and student1, one assignment and one graded
    /// submission by student1.
    private func seed(app: Application, courseGate: Bool, assignmentGate: Bool) async throws -> Seed {
        let instructorCookie = try await wrLoginAsInstructor(on: app)
        let instructor = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
        try await wrEnrollUser(instructor, on: app)
        let studentCookie = try await wrLoginAsStudent(on: app)
        let student = try await wrStudentUser(on: app)
        try await wrEnrollUser(student, on: app)

        let course = try await wrMakeCourse(on: app)
        course.aiFeedbackEnabled = courseGate
        try await course.save(on: app.db)
        try await wrInsertSetup(id: "setup_aif", on: app)
        let assignment = try await wrInsertAssignment(testSetupID: "setup_aif", title: "Reflect Lab", isOpen: true, on: app)
        assignment.aiFeedbackEnabled = assignmentGate
        try await assignment.save(on: app.db)
        try await wrInsertSubmission(id: "sub_aif", testSetupID: "setup_aif", userID: student.requireID(), on: app)
        try await wrInsertResult(submissionID: "sub_aif", outcomes: [wrMakeOutcome(name: "test.sh")], on: app)
        return Seed(
            instructorCookie: instructorCookie, studentCookie: studentCookie,
            assignment: assignment, course: course)
    }

    private func post(
        _ path: String, form: [String: String], cookie: String, csrfFrom page: String, on app: Application
    ) async throws -> HTTPStatus {
        let (csrf, session) = try await csrfFields(for: page, cookie: cookie, on: app)
        var status = HTTPStatus.imATeapot
        var body = form
        body["_csrf"] = csrf
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: session)
                try req.content.encode(body, as: .urlEncodedForm)
            },
            afterResponse: { res in status = res.status })
        return status
    }

    /// The student's feedback row, as the review page or an agent would make it.
    private func draftRow(for seed: Seed, text: String, on app: Application) async throws -> APIReflectionFeedback {
        let student = try await wrStudentUser(on: app)
        let row = APIReflectionFeedback(
            assignmentID: try seed.assignment.requireID(), userID: try student.requireID(), handle: "R-7Q2M4K")
        row.state = .draft
        row.draftText = text
        row.submissionID = "sub_aif"
        try await row.save(on: app.db)
        return row
    }

    // MARK: - The course gate

    @Test func onlyAnAdminSetsTheCourseGate() async throws {
        try await withWebRoutesApp { app in
            let seed = try await seed(app: app, courseGate: false, assignmentGate: false)
            let courseID = try seed.course.requireID().uuidString

            let denied = try await post(
                "/admin/courses/\(courseID)/ai-feedback", form: ["enabled": "on"],
                cookie: seed.instructorCookie,
                csrfFrom: "/instructor/\(seed.assignment.publicID)/edit", on: app)
            #expect(denied != .seeOther)
            #expect(try await APICourse.find(seed.course.id, on: app.db)?.aiFeedbackEnabled != true)

            let adminCookie = try await loginAsAdmin("aif_admin", on: app)
            let allowed = try await post(
                "/admin/courses/\(courseID)/ai-feedback", form: ["enabled": "on"],
                cookie: adminCookie, csrfFrom: "/admin", on: app)
            #expect(allowed == .seeOther)
            #expect(try await APICourse.find(seed.course.id, on: app.db)?.aiFeedbackEnabled == true)

            _ = try await post(
                "/admin/courses/\(courseID)/ai-feedback", form: [:],
                cookie: adminCookie, csrfFrom: "/admin", on: app)
            #expect(try await APICourse.find(seed.course.id, on: app.db)?.aiFeedbackEnabled == false)
        }
    }

    // MARK: - The assignment gate

    @Test func theAssignmentGateIsRefusedWhileTheCourseGateIsOff() async throws {
        try await withWebRoutesApp { app in
            let seed = try await seed(app: app, courseGate: false, assignmentGate: false)
            let id = seed.assignment.publicID
            _ = try await post(
                "/instructor/\(id)/ai-feedback", form: ["enabled": "on"],
                cookie: seed.instructorCookie, csrfFrom: "/instructor/\(id)/edit", on: app)
            #expect(try await APIAssignment.find(seed.assignment.id, on: app.db)?.aiFeedbackEnabled != true)
        }
    }

    @Test func anInstructorSetsTheAssignmentGateOnceTheCourseGateIsOn() async throws {
        try await withWebRoutesApp { app in
            let seed = try await seed(app: app, courseGate: true, assignmentGate: false)
            let id = seed.assignment.publicID
            let html = try await getHTML("/instructor/\(id)/edit", cookie: seed.instructorCookie, on: app)
            #expect(html.contains("/instructor/\(id)/ai-feedback"))

            _ = try await post(
                "/instructor/\(id)/ai-feedback", form: ["enabled": "on"],
                cookie: seed.instructorCookie, csrfFrom: "/instructor/\(id)/edit", on: app)
            #expect(try await APIAssignment.find(seed.assignment.id, on: app.db)?.aiFeedbackEnabled == true)
        }
    }

    @Test func theEditPageHidesTheAssignmentGateWhileTheCourseGateIsOff() async throws {
        try await withWebRoutesApp { app in
            let seed = try await seed(app: app, courseGate: false, assignmentGate: false)
            let id = seed.assignment.publicID
            let html = try await getHTML("/instructor/\(id)/edit", cookie: seed.instructorCookie, on: app)
            #expect(!html.contains("/instructor/\(id)/ai-feedback"))
        }
    }

    // MARK: - Review and release

    @Test func aDraftReachesTheStudentOnlyAfterRelease() async throws {
        try await withWebRoutesApp { app in
            let seed = try await seed(app: app, courseGate: true, assignmentGate: true)
            let id = seed.assignment.publicID
            _ = try await draftRow(for: seed, text: "Agent draft text.", on: app)

            let review = try await getHTML("/instructor/\(id)/feedback", cookie: seed.instructorCookie, on: app)
            #expect(review.contains("Agent draft text."))
            #expect(review.contains("R-7Q2M4K"))

            var studentPage = try await getHTML("/submissions/sub_aif", cookie: seed.studentCookie, on: app)
            #expect(!studentPage.contains("Agent draft text."))

            let status = try await post(
                "/instructor/\(id)/feedback",
                form: ["handle": "R-7Q2M4K", "action": "release", "feedback": "Reviewed and edited."],
                cookie: seed.instructorCookie, csrfFrom: "/instructor/\(id)/feedback", on: app)
            #expect(status == .seeOther)

            studentPage = try await getHTML("/submissions/sub_aif", cookie: seed.studentCookie, on: app)
            #expect(studentPage.contains("Reviewed and edited."))
            #expect(studentPage.contains("reviewed by course staff"))

            _ = try await post(
                "/instructor/\(id)/feedback", form: ["handle": "R-7Q2M4K", "action": "discard"],
                cookie: seed.instructorCookie, csrfFrom: "/instructor/\(id)/feedback", on: app)
            studentPage = try await getHTML("/submissions/sub_aif", cookie: seed.studentCookie, on: app)
            #expect(!studentPage.contains("Reviewed and edited."))
        }
    }

    @Test func aStudentCannotReachTheReviewPage() async throws {
        try await withWebRoutesApp { app in
            let seed = try await seed(app: app, courseGate: true, assignmentGate: true)
            _ = try await draftRow(for: seed, text: "Agent draft text.", on: app)
            var body = ""
            try await app.asyncTest(
                .GET, "/instructor/\(seed.assignment.publicID)/feedback",
                beforeRequest: { req in req.headers.add(name: .cookie, value: seed.studentCookie) },
                afterResponse: { res in body = res.body.string })
            #expect(!body.contains("Agent draft text."))
        }
    }

    // MARK: - The student notice

    @Test func theUploadPageSaysSoWhenBothGatesAreOn() async throws {
        try await withWebRoutesApp { app in
            let seed = try await seed(app: app, courseGate: true, assignmentGate: true)
            let html = try await getHTML("/testsetups/setup_aif/submit", cookie: seed.studentCookie, on: app)
            #expect(html.contains("ai-assisted-feedback.md#for-students"))
        }
    }

    @Test func theUploadPageSaysNothingWhileAGateIsOff() async throws {
        try await withWebRoutesApp { app in
            let seed = try await seed(app: app, courseGate: true, assignmentGate: false)
            let html = try await getHTML("/testsetups/setup_aif/submit", cookie: seed.studentCookie, on: app)
            #expect(!html.contains("ai-assisted-feedback.md"))
        }
    }
}
