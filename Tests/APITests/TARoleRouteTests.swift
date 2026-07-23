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

    /// The handful of values each route test threads through its request.
    private struct Fixture {
        let courseID: UUID
        let assignmentID: String
        let taUserID: UUID
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
            taUserID: try taUser.requireID(), csrf: csrf, sessionCookie: sessionCookie)
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

    // MARK: - A per-course STUDENT is shut out of the instructor area entirely

    @Test func studentCannotEditAssignmentSuite() async throws {
        try await withApp(app) { _ in
            // Same fixture, acting user enrolled as a plain `.student` — the
            // `/instructor` gate (role >= .ta) rejects them before any handler.
            let fx = try await fixture(role: .student)
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
                        res.status == .forbidden,
                        "a student must not edit assignment content, got \(res.status)")
                })
        }
    }

    @Test func studentCannotRetestSubmissions() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(role: .student)
            try await app.asyncTest(
                .POST, "/instructor/\(fx.assignmentID)/retest",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: fx.sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: fx.csrf)
                    req.headers.contentType = .urlEncodedForm
                    req.body = ByteBuffer(string: "")
                },
                afterResponse: { res in
                    #expect(
                        res.status == .forbidden,
                        "a student must not retest submissions, got \(res.status)")
                })
        }
    }

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
