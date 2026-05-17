// Tests/APITests/WebRoutesSubmitHistoryTests.swift
//
// Split from WebRoutesTests.swift.  See WebRoutesTestCase.swift for
// shared helpers (auth, seeding, submitMultipartBody, submitOnceAs).

import Core
import Fluent
import Foundation
import XCTVapor
import XCTest

@testable import chickadee_server

final class WebRoutesSubmitHistoryTests: WebRoutesTestCase {

    // MARK: - GET /testsetups/:id/submit

    func testSubmitFormRendersForStudent() async throws {
        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        try await enrollUser(user)
        try await insertSetup(id: "setup_sub")

        try await app.asyncTest(
            .GET, "/testsetups/setup_sub/submit",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
            })
    }

    func testSubmitForm404ForMissingSetup() async throws {
        let cookie = try await loginAsStudent()

        try await app.asyncTest(
            .GET, "/testsetups/nonexistent/submit",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .notFound)
            })
    }

    func testSubmitPostRejectsOverdueAssignmentsAndPersistsClosure() async throws {
        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        try await enrollUser(user)
        _ = try await insertSetup(id: "setup_submit_overdue")
        let assignment = try await insertAssignment(
            testSetupID: "setup_submit_overdue",
            title: "Late Lab",
            isOpen: true,
            dueAt: Date().addingTimeInterval(-60)
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
                req.body = .init(buffer: submitMultipartBody(boundary: boundary, csrfToken: csrf))
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .forbidden)
                XCTAssertTrue(res.body.string.contains("closed"))
            })

        let refreshedOptional = try await APIAssignment.find(assignment.id, on: app.db)
        XCTAssertNotNil(refreshedOptional)
        let refreshed = refreshedOptional!
        XCTAssertFalse(refreshed.isOpen)
    }

    // MARK: - GET /testsetups/:id/history

    func testHistoryShowsSubmissions() async throws {
        let cookie = try await loginAsStudent()
        let user = try await studentUser()
        let userID = try user.requireID()
        try await insertSetup(id: "setup_hist")
        try await insertAssignment(testSetupID: "setup_hist", title: "History Test", isOpen: true)
        try await insertSubmission(id: "sub_h1", testSetupID: "setup_hist", userID: userID, attemptNumber: 1)
        try await insertSubmission(id: "sub_h2", testSetupID: "setup_hist", userID: userID, attemptNumber: 2)

        try await app.asyncTest(
            .GET, "/testsetups/setup_hist/history",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let html = res.body.string
                XCTAssertTrue(html.contains("History Test"), "Should show assignment title")
            })
    }

    func testHistory404ForMissingSetup() async throws {
        let cookie = try await loginAsStudent()

        try await app.asyncTest(
            .GET, "/testsetups/nonexistent/history",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .notFound)
            })
    }
}
