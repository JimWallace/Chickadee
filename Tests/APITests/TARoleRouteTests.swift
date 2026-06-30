// Tests/APITests/TARoleRouteTests.swift
//
// #417 Slice E — the TA per-course role. A TA may enter the instructor area and
// do the content-editing / grading actions (floor `.ta`), but NOT the
// instructor-only actions (enrollment management, delete, deadlines, archive —
// floor `.instructor`). The acting user here is a *global student* with a
// per-course `.ta` enrollment, so these tests also prove authority is purely
// per-course (the deployment role is irrelevant).

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class TARoleRouteTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-ta-role")
    }

    /// A non-archived `.closed` course + setup + published assignment, with
    /// `ta_user` (a *global student*) enrolled at the given per-course role.
    /// `.closed` so the user isn't auto-enrolled at some other role; the manual
    /// enrollment makes this their only — hence active — course.
    private func fixture(
        role: CourseRole
    ) async throws -> (
        courseID: UUID, assignmentID: String, taUserID: UUID, csrf: String, sessionCookie: String
    ) {
        let course = try await makeTestCourse(on: app, code: "TAROLE", name: "TA Role", mode: .closed)
        let courseID = try course.requireID()
        try await makeTestSetup(on: app, id: "ta_setup", courseID: courseID)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: "ta_setup", courseID: courseID, title: "Lab")

        let cookie = try await loginUser(
            username: "ta_user", password: "pw", role: "student", on: app)
        let taUser = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "ta_user").first())
        try await APICourseEnrollment(
            userID: try taUser.requireID(), courseID: courseID, role: role
        ).save(on: app.db)

        let (csrf, sessionCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)
        return (courseID, assignment.publicID, try taUser.requireID(), csrf, sessionCookie)
    }

    // MARK: - TA CAN edit assignment content (floor .ta)

    @Test func taCanEditAssignmentSuite() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(role: .ta)
            try await app.asyncTest(
                .PUT, "/instructor/\(fx.assignmentID)/suite",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: fx.sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: fx.csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: #"{"items":[]}"#)
                },
                afterResponse: { res in
                    #expect(
                        res.status == .ok, "a TA may edit assignment content, got \(res.status): \(res.body.string)")
                })
        }
    }

    // MARK: - TA CANNOT do instructor-only actions (floor .instructor)

    @Test func taCannotDeleteAssignment() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(role: .ta)
            try await app.asyncTest(
                .POST, "/instructor/\(fx.assignmentID)/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: fx.sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: fx.csrf)
                    req.headers.contentType = .urlEncodedForm
                    req.body = ByteBuffer(string: "")
                },
                afterResponse: { res in
                    #expect(
                        res.status == .forbidden,
                        "a TA must not delete an assignment, got \(res.status)")
                })
        }
    }

    @Test func taCannotManageEnrollment() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(role: .ta)
            // Set-role is enrollment management (instructor floor).
            try await app.asyncTest(
                .POST, "/courses/\(fx.courseID)/role/\(fx.taUserID)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: fx.sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: fx.csrf)
                    req.headers.contentType = .urlEncodedForm
                    req.body = ByteBuffer(string: "role=student")
                },
                afterResponse: { res in
                    #expect(
                        res.status == .forbidden,
                        "a TA must not manage enrollment/staff, got \(res.status)")
                })
        }
    }

    // MARK: - An instructor in the same fixture CAN do the instructor-only action

    @Test func instructorCanDeleteAssignment() async throws {
        try await withApp(app) { _ in
            // Same shape, but the acting user holds the per-course .instructor
            // role — the delete (instructor floor) now succeeds (303 redirect),
            // attributing the TA's 403 above to the role, not the fixture.
            let fx = try await fixture(role: .instructor)
            try await app.asyncTest(
                .POST, "/instructor/\(fx.assignmentID)/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: fx.sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: fx.csrf)
                    req.headers.contentType = .urlEncodedForm
                    req.body = ByteBuffer(string: "")
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther, "an instructor may delete, got \(res.status)")
                })
        }
    }
}
