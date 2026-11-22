// Tests/APITests/Pages/WebRoutesSubmitHistoryTests.swift
//
// Split from WebRoutesTests.swift.  See WebRoutesHelpers.swift for the
// `withTestApp` lifecycle wrapper and free-function helpers (auth,
// seeding, submitMultipartBody, submitOnceAs).

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct WebRoutesSubmitHistoryTests {

    // MARK: - GET /testsetups/:id/submit

    @Test func submitFormRendersForStudent() async throws {
        try await withTestApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let user = try await wrStudentUser(on: app)
            try await wrEnrollUser(user, on: app)
            try await wrInsertSetup(id: "setup_sub", on: app)

            try await app.asyncTest(
                .GET, "/testsetups/setup_sub/submit",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                })
        }
    }

    @Test func submitForm404ForMissingSetup() async throws {
        try await withTestApp { app in
            let cookie = try await wrLoginAsStudent(on: app)

            try await app.asyncTest(
                .GET, "/testsetups/nonexistent/submit",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })
        }
    }

    /// A browser-graded assignment is submitted from the notebook page, so
    /// the upload form sends the student there.
    @Test func submitFormRedirectsABrowserGradedAssignmentToTheNotebook() async throws {
        try await withTestApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await wrInsertSetup(id: "setup_sub_browser", manifest: TestManifests.browserEmpty, on: app)
            try await wrEnrollUser(try await wrStudentUser(on: app), on: app)

            let res = try await getResponse("/testsetups/setup_sub_browser/submit", cookie: cookie, on: app)
            #expect(res.status == .seeOther)
            #expect(res.headers.first(name: .location) == "/testsetups/setup_sub_browser/notebook")
        }
    }

    /// The form shows the refusal of the previous upload, in the words of
    /// the hint, when the POST sent the student back with `error=filetype`.
    @Test func submitFormShowsTheFileTypeRefusal() async throws {
        try await withTestApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await wrInsertSetup(id: "setup_sub_refused", manifest: Self.racketManifest, on: app)
            try await wrEnrollUser(try await wrStudentUser(on: app), on: app)

            let plain = try await getResponse("/testsetups/setup_sub_refused/submit", cookie: cookie, on: app)
            #expect(plain.status == .ok)
            #expect(!plain.body.string.contains("That file type is not accepted."))

            let refused = try await getResponse(
                "/testsetups/setup_sub_refused/submit?error=filetype", cookie: cookie, on: app)
            #expect(refused.status == .ok)
            #expect(refused.body.string.contains("That file type is not accepted. Racket assignment"))
        }
    }

    static let racketManifest = """
        {"schemaVersion":1,"language":"racket","requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}
        """

    /// Posts the standard one-file upload (`submission.py`) to `setupID` as
    /// the enrolled student1 and returns the response status and Location.
    private func postUpload(
        setupID: String, cookie: String, on app: Application
    ) async throws -> (status: HTTPStatus, location: String?) {
        let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
        let res = try await wrPostSubmitUpload(
            setupID: setupID, csrfToken: csrf, sessionCookie: sessionCookie, on: app)
        return (res.status, res.headers.first(name: .location))
    }

    private func submissionCount(setupID: String, on app: Application) async throws -> Int {
        try await APISubmission.query(on: app.db).filter(\.$testSetupID == setupID).count()
    }

    @Test func submitPost404ForMissingSetup() async throws {
        try await withTestApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let (status, _) = try await postUpload(setupID: "nonexistent", cookie: cookie, on: app)
            #expect(status == .notFound)
        }
    }

    /// A direct POST to a browser-graded assignment stores nothing: the
    /// student goes to the notebook page, where the browser grades.
    @Test func submitPostRedirectsABrowserGradedAssignmentWithoutStoring() async throws {
        try await withTestApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await wrInsertSetup(id: "setup_post_browser", manifest: TestManifests.browserEmpty, on: app)
            try await wrEnrollUser(try await wrStudentUser(on: app), on: app)

            let (status, location) = try await postUpload(setupID: "setup_post_browser", cookie: cookie, on: app)
            #expect(status == .seeOther)
            #expect(location == "/testsetups/setup_post_browser/notebook")
            #expect(try await submissionCount(setupID: "setup_post_browser", on: app) == 0)
        }
    }

    /// The server-side file-type gate: a `.py` upload to a Racket assignment
    /// goes back to the form with `error=filetype`, and no row is stored.
    @Test func submitPostRefusesAFileTypeTheAssignmentDoesNotAccept() async throws {
        try await withTestApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await wrInsertSetup(id: "setup_post_racket", manifest: Self.racketManifest, on: app)
            try await wrEnrollUser(try await wrStudentUser(on: app), on: app)

            let (status, location) = try await postUpload(setupID: "setup_post_racket", cookie: cookie, on: app)
            #expect(status == .seeOther)
            #expect(location == "/testsetups/setup_post_racket/submit?error=filetype")
            #expect(try await submissionCount(setupID: "setup_post_racket", on: app) == 0)
        }
    }

    @Test func submitPostRejectsOverdueAssignmentsAndPersistsClosure() async throws {
        try await withTestApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let user = try await wrStudentUser(on: app)
            try await wrEnrollUser(user, on: app)
            _ = try await wrInsertSetup(id: "setup_submit_overdue", on: app)
            let assignment = try await wrInsertAssignment(
                testSetupID: "setup_submit_overdue",
                title: "Late Lab",
                isOpen: true,
                dueAt: Date().addingTimeInterval(-60),
                on: app
            )
            // The student opened this while it was open (here: a prior
            // submission) so the closed-assignment gate lets them reach the
            // submit form; the POST is still rejected for being past due.
            try await wrInsertSubmission(
                id: "sub_overdue_prior",
                testSetupID: "setup_submit_overdue",
                userID: try user.requireID(),
                on: app
            )

            let (csrf, sessionCookie) = try await csrfFields(
                for: "/testsetups/setup_submit_overdue/submit",
                cookie: cookie,
                on: app
            )
            let res = try await wrPostSubmitUpload(
                setupID: "setup_submit_overdue", csrfToken: csrf, sessionCookie: sessionCookie, on: app)
            #expect(res.status == .forbidden)
            #expect(res.body.string.contains("closed"))

            let refreshed = try #require(try await APIAssignment.find(assignment.id, on: app.db))
            #expect(!refreshed.isOpen)
        }
    }

    /// A test setup with no assignment row (a draft, or a setup that the REST
    /// upload made) gets no enrollment check from `requireOpenStudentAssignment`,
    /// so the route must check enrollment itself, as the form does. Before
    /// this, any signed-in user could queue a submission against another
    /// course's draft.
    @Test func submitPostRefusesAStudentWhoIsNotEnrolledInTheCourse() async throws {
        try await withTestApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await wrInsertSetup(id: "setup_submit_foreign", on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)

            let res = try await wrPostSubmitUpload(
                setupID: "setup_submit_foreign", csrfToken: csrf, sessionCookie: sessionCookie, on: app)
            #expect(res.status == .forbidden)

            let rows = try await APISubmission.query(on: app.db)
                .filter(\.$testSetupID == "setup_submit_foreign").count()
            #expect(rows == 0)
        }
    }

    // MARK: - GET /testsetups/:id/history

    @Test func historyShowsSubmissions() async throws {
        try await withTestApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let user = try await wrStudentUser(on: app)
            let userID = try user.requireID()
            try await wrInsertSetup(id: "setup_hist", on: app)
            try await wrInsertAssignment(testSetupID: "setup_hist", title: "History Test", isOpen: true, on: app)
            try await wrInsertSubmission(
                id: "sub_h1", testSetupID: "setup_hist", userID: userID, attemptNumber: 1, on: app)
            try await wrInsertSubmission(
                id: "sub_h2", testSetupID: "setup_hist", userID: userID, attemptNumber: 2, on: app)

            try await app.asyncTest(
                .GET, "/testsetups/setup_hist/history",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("History Test"), "Should show assignment title")
                })
        }
    }

    @Test func history404ForMissingSetup() async throws {
        try await withTestApp { app in
            let cookie = try await wrLoginAsStudent(on: app)

            try await app.asyncTest(
                .GET, "/testsetups/nonexistent/history",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })
        }
    }
}
