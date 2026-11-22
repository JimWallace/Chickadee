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
            let boundary = "late-submit-boundary"

            try await app.asyncTest(
                .POST, "/testsetups/setup_submit_overdue/submit",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart",
                        subType: "form-data",
                        parameters: ["boundary": boundary]
                    )
                    req.body = .init(buffer: wrSubmitMultipartBody(boundary: boundary, csrfToken: csrf))
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                    #expect(res.body.string.contains("closed"))
                })

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
            let boundary = "foreign-submit-boundary"

            try await app.asyncTest(
                .POST, "/testsetups/setup_submit_foreign/submit",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                    req.body = .init(buffer: wrSubmitMultipartBody(boundary: boundary, csrfToken: csrf))
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })

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
