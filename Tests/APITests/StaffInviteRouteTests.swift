// Tests/APITests/StaffInviteRouteTests.swift
//
// #417 Slice F — self-serve instructor staff invites. A per-course *instructor*
// adds a co-instructor or TA to their course by username or email; an unknown
// identifier mints an SSO-style placeholder account enrolled at the chosen staff
// role (so the role sticks, unlike the CSV pre-enrollment path which seeds to
// student). TAs are read-only on the roster and cannot invite. Authority is
// purely per-course: the acting instructor here is a *global student*.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class StaffInviteRouteTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-staff-invite")
    }

    /// A non-archived `.closed` course with `actor` (a *global student*) enrolled
    /// at `role` — their only, hence active, course.
    private struct Fixture {
        let courseID: UUID
        let csrf: String
        let sessionCookie: String
    }

    private func fixture(actorRole: CourseRole) async throws -> Fixture {
        let course = try await makeTestCourse(on: app, code: "STAFF", name: "Staff", mode: .closed)
        let courseID = try course.requireID()

        let cookie = try await loginUser(
            username: "acting_user", password: "pw", role: "student", on: app)
        let actor = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "acting_user").first())
        try await APICourseEnrollment(
            userID: try actor.requireID(), courseID: courseID, role: actorRole
        ).save(on: app.db)

        let (csrf, sessionCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)
        return Fixture(courseID: courseID, csrf: csrf, sessionCookie: sessionCookie)
    }

    private func postStaff(
        _ fx: Fixture, identifier: String, role: String
    ) async throws -> (status: HTTPStatus, location: String?) {
        var out: (HTTPStatus, String?) = (.internalServerError, nil)
        try await app.asyncTest(
            .POST, "/courses/\(fx.courseID)/staff",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: fx.sessionCookie)
                req.headers.add(name: "x-csrf-token", value: fx.csrf)
                req.headers.contentType = .urlEncodedForm
                req.body = ByteBuffer(string: "identifier=\(identifier)&role=\(role)")
            },
            afterResponse: { res in
                out = (res.status, res.headers.first(name: .location))
            })
        return out
    }

    private func enrollment(userID: UUID, courseID: UUID) async throws -> APICourseEnrollment? {
        try await APICourseEnrollment.query(on: app.db)
            .filter(\.$course.$id == courseID)
            .filter(\.$userID == userID)
            .first()
    }

    // MARK: - Instructor can invite (floor .instructor)

    @Test func instructorInvitesUnknownUser_mintsPlaceholderStaff() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(actorRole: .instructor)
            let res = try await postStaff(fx, identifier: "brand_new_ta", role: "ta")
            #expect(res.status == .seeOther)
            #expect(res.location?.contains("staffAdded=1") == true)

            let created = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "brand_new_ta").first(),
                "an unknown identifier should mint a placeholder account")
            #expect(created.passwordHash.isEmpty, "placeholder has no local password")
            let enr = try #require(try await enrollment(userID: created.requireID(), courseID: fx.courseID))
            #expect(enr.role == .ta, "placeholder enrolled at the chosen staff role")
        }
    }

    @Test func instructorInvitesExistingUser_asInstructor() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(actorRole: .instructor)
            let existing = try await makeTestUser(on: app, username: "existing_prof", role: "student")
            let existingID = try existing.requireID()

            let res = try await postStaff(fx, identifier: "existing_prof", role: "instructor")
            #expect(res.status == .seeOther)

            let enr = try #require(try await enrollment(userID: existingID, courseID: fx.courseID))
            #expect(enr.role == .instructor)
            // No duplicate account was created.
            let count = try await APIUser.query(on: app.db)
                .filter(\.$username == "existing_prof").count()
            #expect(count == 1)
        }
    }

    @Test func inviteExistingStudent_promotesInPlace() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(actorRole: .instructor)
            let student = try await makeTestUser(on: app, username: "enrolled_stu", role: "student")
            let studentID = try student.requireID()
            try await APICourseEnrollment(userID: studentID, courseID: fx.courseID, role: .student)
                .save(on: app.db)

            let res = try await postStaff(fx, identifier: "enrolled_stu", role: "ta")
            #expect(res.status == .seeOther)

            // Same enrollment row, promoted — not a second row.
            let rows = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$course.$id == fx.courseID)
                .filter(\.$userID == studentID)
                .all()
            #expect(rows.count == 1)
            #expect(rows.first?.role == .ta)
        }
    }

    // MARK: - Guards

    @Test func taCannotInviteStaff() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(actorRole: .ta)
            let res = try await postStaff(fx, identifier: "someone_new", role: "ta")
            #expect(res.status == .forbidden, "a TA must not invite staff, got \(res.status)")
            // Nothing was created.
            let count = try await APIUser.query(on: app.db)
                .filter(\.$username == "someone_new").count()
            #expect(count == 0)
        }
    }

    @Test func inviteRejectsStudentRole() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture(actorRole: .instructor)
            let res = try await postStaff(fx, identifier: "not_staff", role: "student")
            #expect(res.status == .seeOther)
            #expect(res.location?.contains("staffError=role") == true)
            // The student-role invite is refused before any account/enrollment is made.
            let count = try await APIUser.query(on: app.db)
                .filter(\.$username == "not_staff").count()
            #expect(count == 0)
        }
    }
}
