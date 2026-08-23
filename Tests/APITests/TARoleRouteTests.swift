// Tests/APITests/TARoleRouteTests.swift
//
// #417 Slice E — the TA per-course role. A TA may enter the instructor area and
// do the content-editing / grading actions (floor `.ta`), but NOT the
// instructor-only actions (enrollment management, delete, deadlines, archive —
// floor `.instructor`). The acting user here is a *global student* with a
// per-course `.ta` enrollment, so these tests also prove authority is purely
// per-course (the deployment role is irrelevant).
//
// WHAT IS LEFT HERE, AND WHY. This suite used to carry eight spot tests, and
// they were the *only* thing holding the TA boundary — which meant the boundary
// held exactly on the routes someone had remembered to write a test for.
// `RouteAuthorizationMatrixTests` now derives that boundary: it walks the live
// route table and crosses every parameterized `/instructor` and `/courses`
// route with `CourseRole.allCases`, asserting each route's declared floor. Six
// of the eight said something it now says for every route at once — a TA is
// denied on `POST /instructor/:assignmentID/delete` and
// `POST /courses/:courseID/role/:userID`, an instructor is not, and a per-course
// student is denied on `PUT /instructor/:assignmentID/suite` and
// `POST /instructor/:assignmentID/retest` — so they were removed rather than
// left to drift out of sync with the matrix.
//
// The two that remain are on routes the matrix structurally cannot reach: the
// per-student action routes are vanity-URL routes whose first path component is
// the `:courseCode` PARAMETER, and the matrix walks only routes rooted at the
// constants `instructor` or `courses`. They also assert behaviour rather than
// authorization — that the extension row is really created and really removed —
// which is outside what a status-code matrix can see.

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

    /// The handful of values each route test threads through its request.
    private struct Fixture {
        let courseID: UUID
        let assignmentID: String
        let csrf: String
        let sessionCookie: String
    }

    /// A non-archived `.closed` course + setup + published assignment, with
    /// `ta_user` (a *global student*) enrolled at the given per-course role.
    /// `.closed` so the user isn't auto-enrolled at some other role; the manual
    /// enrollment makes this their only — hence active — course.
    private func fixture(role: CourseRole) async throws -> Fixture {
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
        return Fixture(
            courseID: courseID, assignmentID: assignment.publicID,
            csrf: csrf, sessionCookie: sessionCookie)
    }

    /// A fresh student enrolled as `.student` in `courseID`, returned with their
    /// URL token — the `:urlToken` path segment the per-student action routes
    /// (extension grant/revoke) key off.
    private func enrolledTarget(courseID: UUID) async throws -> (student: APIUser, urlToken: String) {
        let target = APIUser(
            username: "ext_target", passwordHash: try testPasswordHash("pw"), role: "student")
        try await target.save(on: app.db)
        try await APICourseEnrollment(
            userID: try target.requireID(), courseID: courseID, role: .student
        ).save(on: app.db)
        return (target, try target.requireURLToken())
    }

    // MARK: - TA CAN grant an individual accommodation (floor .ta)

    // A per-student deadline extension is an individual accommodation — a
    // sibling of grade-override, floored at `.ta`, NOT the assignment-wide
    // deadline. Regression for the reported 403: these endpoints used to
    // require `.instructor`, so a TA got a 403 on Save even though the
    // student-submissions page shows them the extension button right beside
    // retest / grade-override (both `.ta`), which they can use.
    @Test func taCanGrantAndRevokeExtension() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(role: .ta)
            let target = try await enrolledTarget(courseID: fx.courseID)
            let targetID = try target.student.requireID()

            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = TimeZone(identifier: "America/Toronto")
            fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
            let futureInput = fmt.string(from: Date().addingTimeInterval(86_400))

            // Grant → 303 redirect, exactly one row created.
            try await app.asyncTest(
                .POST, "/TAROLE/students/\(target.urlToken)/assignments/\(fx.assignmentID)/extension",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: fx.sessionCookie)
                    try req.content.encode(
                        ["_csrf": fx.csrf, "extendedDueAt": futureInput, "note": "Accommodation"],
                        as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(
                        res.status == .seeOther,
                        "a TA may grant a per-student extension, got \(res.status): \(res.body.string)")
                })
            let afterGrant = try await APIAssignmentExtension.query(on: app.db)
                .filter(\.$userID == targetID).count()
            #expect(afterGrant == 1, "the extension row must be created")

            // Revoke → 303 redirect, row removed.
            try await app.asyncTest(
                .POST,
                "/TAROLE/students/\(target.urlToken)/assignments/\(fx.assignmentID)/extension/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: fx.sessionCookie)
                    try req.content.encode(["_csrf": fx.csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(
                        res.status == .seeOther, "a TA may revoke a per-student extension, got \(res.status)")
                })
            let afterRevoke = try await APIAssignmentExtension.query(on: app.db)
                .filter(\.$userID == targetID).count()
            #expect(afterRevoke == 0, "the extension row must be removed")
        }
    }

    // MARK: - A per-course STUDENT is shut out of the same route

    @Test func studentCannotGrantExtension() async throws {
        try await withApp(app) { _ in
            // Lowering the extension floor to `.ta` must not leak down to a
            // per-course student — the `/instructor` staff gate (role >= .ta)
            // still shuts them out before the handler runs.
            let fx = try await fixture(role: .student)
            let target = try await enrolledTarget(courseID: fx.courseID)
            try await app.asyncTest(
                .POST, "/TAROLE/students/\(target.urlToken)/assignments/\(fx.assignmentID)/extension",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: fx.sessionCookie)
                    try req.content.encode(
                        ["_csrf": fx.csrf, "extendedDueAt": "2099-01-01T00:00", "note": ""],
                        as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(
                        res.status == .forbidden,
                        "a student must not grant extensions, got \(res.status)")
                })
        }
    }
}
