// Tests/APITests/Courses/CourseEnrollmentRouteRefusalTests.swift
//
// The per-course gates and refusals of the instructor roster routes in
// `CourseAdminRoutes+Enrollment.swift`. `RouteAuthorizationMatrixTests` pins
// each route's status floor; this suite checks what a refusal leaves behind:
// a TA of the course and an instructor of a different course both get 403,
// and the roster stays as it was. It also covers the malformed ids, the
// missing rows, and the role change that the instructor Students tab sends.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class CourseEnrollmentRouteRefusalTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-enroll-refusals")
    }

    private struct Reply {
        let status: HTTPStatus
        let location: String?
    }

    /// A `.closed` course, so no login enrolls anybody in it by itself.
    private func course(_ code: String) async throws -> UUID {
        try await makeTestCourse(on: app, code: code, mode: .closed).requireID()
    }

    /// Signs `username` in (a deployment `user`) and enrolls them in
    /// `courseID` at `role`. Returns the session cookie.
    private func signIn(_ username: String, as role: CourseRole, in courseID: UUID) async throws -> String {
        let cookie = try await loginUser(username: username, password: "pw-\(username)", role: "user", on: app)
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first())
        try await APICourseEnrollment(userID: try user.requireID(), courseID: courseID, role: role).save(on: app.db)
        return cookie
    }

    private func enrolled(_ username: String, as role: CourseRole, in courseID: UUID) async throws -> UUID {
        let user = try await makeTestUser(on: app, username: username, role: "user")
        let userID = try user.requireID()
        try await APICourseEnrollment(userID: userID, courseID: courseID, role: role).save(on: app.db)
        return userID
    }

    private func post(_ path: String, fields: [String: String] = [:], cookie: String) async throws -> Reply {
        let (token, bound) = try await csrfFields(for: "/account", cookie: cookie, on: app)
        var reply = Reply(status: .internalServerError, location: nil)
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: bound)
                try req.content.encode(fields.merging(["_csrf": token]) { $1 }, as: .urlEncodedForm)
            },
            afterResponse: { res in
                reply = Reply(status: res.status, location: res.headers.first(name: .location))
            })
        return reply
    }

    private func role(of userID: UUID, in courseID: UUID) async throws -> CourseRole? {
        try await APICourseEnrollment.query(on: app.db)
            .filter(\.$userID == userID)
            .filter(\.$course.$id == courseID)
            .first()?.role
    }

    private func rosterSize(_ courseID: UUID) async throws -> Int {
        try await APICourseEnrollment.query(on: app.db).filter(\.$course.$id == courseID).count()
    }

    private func preEnrollmentCount(_ courseID: UUID) async throws -> Int {
        try await APIPreEnrollment.query(on: app.db).filter(\.$course.$id == courseID).count()
    }

    // MARK: - A TA cannot manage enrollment

    @Test func aTACannotChangeTheRosterOfItsOwnCourse() async throws {
        try await withApp(app) { _ in
            let courseA = try await course("TAENR101")
            let cookie = try await signIn("roster_ta", as: .ta, in: courseA)
            let studentID = try await enrolled("roster_student", as: .student, in: courseA)
            _ = try await makeTestUser(on: app, username: "roster_newcomer", role: "user")
            let base = "/courses/\(courseA.uuidString)"
            let rosterBefore = try await rosterSize(courseA)

            let enroll = try await post(
                "\(base)/enroll-csv", fields: ["usernames": "roster_newcomer, ghost_user"], cookie: cookie)
            let promote = try await post("\(base)/role/\(studentID.uuidString)", fields: ["role": "ta"], cookie: cookie)
            let unenroll = try await post("\(base)/unenroll/\(studentID.uuidString)", cookie: cookie)
            let invite = try await post(
                "\(base)/staff", fields: ["identifier": "roster_newcomer", "role": "ta"], cookie: cookie)

            #expect(enroll.status == .forbidden)
            #expect(promote.status == .forbidden)
            #expect(unenroll.status == .forbidden)
            #expect(invite.status == .forbidden)
            #expect(try await rosterSize(courseA) == rosterBefore)
            #expect(try await role(of: studentID, in: courseA) == .student)
            #expect(try await preEnrollmentCount(courseA) == 0)
        }
    }

    @Test func aTAIsRefusedTheBulkEnrollForm() async throws {
        try await withApp(app) { _ in
            let courseA = try await course("TAFORM101")
            let cookie = try await signIn("form_ta", as: .ta, in: courseA)

            let response = try await getResponse("/instructor/enroll-csv", cookie: cookie, on: app)

            #expect(response.status == .forbidden)
        }
    }

    @Test func theBulkEnrollFormNeedsAnActiveCourse() async throws {
        try await withApp(app) { _ in
            // An admin passes the area gate with no course at all.
            let cookie = try await loginAsAdmin("form_admin_no_course", on: app)

            let response = try await getResponse("/instructor/enroll-csv", cookie: cookie, on: app)

            #expect(response.status == .badRequest)
        }
    }

    // MARK: - An instructor of course B cannot enroll into course A

    @Test func anInstructorOfAnotherCourseCannotChangeThisRoster() async throws {
        try await withApp(app) { _ in
            let courseA = try await course("CROSSA101")
            let courseB = try await course("CROSSB101")
            let cookie = try await signIn("other_instructor", as: .instructor, in: courseB)
            let studentID = try await enrolled("cross_student", as: .student, in: courseA)
            let newcomerID = try await makeTestUser(on: app, username: "cross_newcomer", role: "user").requireID()
            let base = "/courses/\(courseA.uuidString)"

            let enroll = try await post("\(base)/enroll-csv", fields: ["usernames": "cross_newcomer"], cookie: cookie)
            let promote = try await post(
                "\(base)/role/\(studentID.uuidString)", fields: ["role": "instructor"], cookie: cookie)
            let unenroll = try await post("\(base)/unenroll/\(studentID.uuidString)", cookie: cookie)
            let invite = try await post(
                "\(base)/staff", fields: ["identifier": "other_instructor", "role": "instructor"], cookie: cookie)

            #expect(enroll.status == .forbidden)
            #expect(promote.status == .forbidden)
            #expect(unenroll.status == .forbidden)
            #expect(invite.status == .forbidden)
            #expect(try await role(of: newcomerID, in: courseA) == nil)
            #expect(try await role(of: studentID, in: courseA) == .student)
            #expect(try await rosterSize(courseA) == 1, "the instructor of B must not join A")

            // The same request against the instructor's own course succeeds,
            // so the refusal above is the per-course gate and nothing else.
            let own = try await post(
                "/courses/\(courseB.uuidString)/enroll-csv", fields: ["usernames": "cross_newcomer"], cookie: cookie)
            #expect(own.status == .ok)
            #expect(try await role(of: newcomerID, in: courseB) == .student)
        }
    }

    // MARK: - The role change

    @Test func anInstructorChangesAStudentToATA() async throws {
        try await withApp(app) { _ in
            let courseA = try await course("ROLEOK101")
            let cookie = try await signIn("role_instructor", as: .instructor, in: courseA)
            let studentID = try await enrolled("role_student", as: .student, in: courseA)

            let reply = try await post(
                "/courses/\(courseA.uuidString)/role/\(studentID.uuidString)", fields: ["role": "ta"], cookie: cookie)

            #expect(reply.status == .seeOther)
            #expect(reply.location == "/instructor/students")
            #expect(try await role(of: studentID, in: courseA) == .ta)
            let audited = try await APIAuditLogEntry.query(on: app.db)
                .filter(\.$action == AuditAction.enrollmentRoleChanged.rawValue)
                .filter(\.$targetID == studentID.uuidString)
                .count()
            #expect(audited == 1)
        }
    }

    @Test func aRoleChangeForSomeoneNotOnTheRosterIsNotFound() async throws {
        try await withApp(app) { _ in
            let courseA = try await course("ROLENF101")
            let courseB = try await course("ROLENF102")
            let cookie = try await signIn("nf_instructor", as: .instructor, in: courseA)
            let outsiderID = try await enrolled("nf_outsider", as: .student, in: courseB)

            let reply = try await post(
                "/courses/\(courseA.uuidString)/role/\(outsiderID.uuidString)", fields: ["role": "ta"], cookie: cookie)

            #expect(reply.status == .notFound)
            #expect(try await role(of: outsiderID, in: courseA) == nil)
            #expect(try await role(of: outsiderID, in: courseB) == .student)
        }
    }

    @Test func theLastInstructorCannotDemoteThemself() async throws {
        try await withApp(app) { _ in
            let courseA = try await course("ROLELAST101")
            let cookie = try await signIn("last_instructor", as: .instructor, in: courseA)
            let selfID = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "last_instructor").first()?.id)

            let reply = try await post(
                "/courses/\(courseA.uuidString)/role/\(selfID.uuidString)", fields: ["role": "ta"], cookie: cookie)

            #expect(reply.status == .conflict)
            #expect(try await role(of: selfID, in: courseA) == .instructor)
        }
    }

    // MARK: - Malformed ids

    @Test(arguments: [
        "/courses/not-a-uuid/enroll-csv",
        "/courses/not-a-uuid/unenroll/also-bad",
        "/courses/not-a-uuid/new-handle/also-bad",
        "/courses/not-a-uuid/pre-unenroll/also-bad",
        "/courses/not-a-uuid/pre-enroll/also-bad/register",
        "/courses/not-a-uuid/staff",
        "/courses/not-a-uuid/role/also-bad",
    ])
    func aMalformedIdIsABadRequest(path: String) async throws {
        try await withApp(app) { _ in
            let courseA = try await course("BADID101")
            let cookie = try await signIn("badid_instructor", as: .instructor, in: courseA)
            let rosterBefore = try await rosterSize(courseA)

            let reply = try await post(path, fields: ["role": "ta", "identifier": "x"], cookie: cookie)

            #expect(reply.status == .badRequest)
            #expect(try await rosterSize(courseA) == rosterBefore)
        }
    }

    @Test func aBulkEnrollIntoAnUnknownCourseIsABadRequest() async throws {
        try await withApp(app) { _ in
            let courseA = try await course("UNKCOURSE101")
            let cookie = try await signIn("unk_instructor", as: .instructor, in: courseA)

            let reply = try await post(
                "/courses/\(UUID().uuidString)/enroll-csv", fields: ["usernames": "anyone"], cookie: cookie)

            #expect(reply.status == .badRequest)
        }
    }

    // MARK: - Missing rows

    @Test func aNewHandleForSomeoneNotEnrolledRedirectsWithAnError() async throws {
        try await withApp(app) { _ in
            let courseA = try await course("HANDLENF101")
            let courseB = try await course("HANDLENF102")
            let cookie = try await signIn("handle_instructor", as: .instructor, in: courseA)
            let outsider = try await makeTestUser(on: app, username: "handle_outsider", role: "user")
            outsider.avatarHandle = "steady-heron"
            try await outsider.save(on: app.db)
            try await APICourseEnrollment(userID: try outsider.requireID(), courseID: courseB, role: .student)
                .save(on: app.db)

            let reply = try await post(
                "/courses/\(courseA.uuidString)/new-handle/\(try outsider.requireID().uuidString)", cookie: cookie)

            #expect(reply.status == .seeOther)
            #expect(reply.location == "/instructor/students?handleError=notEnrolled")
            let reloaded = try #require(try await APIUser.find(try outsider.requireID(), on: app.db))
            #expect(reloaded.avatarHandle == "steady-heron")
        }
    }

    @Test func registeringAPreEnrollmentOfAnotherCourseIsNotFound() async throws {
        try await withApp(app) { _ in
            let courseA = try await course("PREREG101")
            let courseB = try await course("PREREG102")
            let cookie = try await signIn("prereg_instructor", as: .instructor, in: courseA)
            let pending = APIPreEnrollment(courseID: courseB, username: "pending_student")
            try await pending.save(on: app.db)
            let pendingID = try pending.requireID()

            let reply = try await post(
                "/courses/\(courseA.uuidString)/pre-enroll/\(pendingID.uuidString)/register", cookie: cookie)

            #expect(reply.status == .notFound)
            #expect(try await APIPreEnrollment.find(pendingID, on: app.db) != nil)
            #expect(try await APIUser.query(on: app.db).filter(\.$username == "pending_student").count() == 0)
        }
    }
}
