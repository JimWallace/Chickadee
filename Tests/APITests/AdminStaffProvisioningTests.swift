// Tests/APITests/AdminStaffProvisioningTests.swift
//
// An admin sets up a course for an instructor who has never logged in: the
// new-course form takes an optional instructor, and the admin course page has
// a staff form. Both share `provisionStaffEnrollment` with the instructor
// roster's staff invite. A placeholder account is made only where SSO can
// adopt it, so the first suite runs under dual sign-in and the second under
// local sign-in only.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

/// Posts a form as `cookie`, with a CSRF token bound to `formPath`, and
/// returns the status and the redirect location.
private func postForm(
    _ path: String, form: [String: String], cookie: String, formPath: String, on app: Application
) async throws -> (status: HTTPStatus, location: String?) {
    let (token, boundCookie) = try await csrfFields(for: formPath, cookie: cookie, on: app)
    var fields = form
    fields["_csrf"] = token
    var out: (HTTPStatus, String?) = (.internalServerError, nil)
    try await app.asyncTest(
        .POST, path,
        beforeRequest: { req in
            req.headers.add(name: .cookie, value: boundCookie)
            try req.content.encode(fields, as: .urlEncodedForm)
        },
        afterResponse: { res in
            out = (res.status, res.headers.first(name: .location))
        })
    return out
}

private func newCourseForm(code: String, instructor: String?) -> [String: String] {
    var form = ["code": code, "name": "Staffing", "termYear": "2026", "termSeason": "fall"]
    form["instructor"] = instructor
    return form
}

private func enrollmentRole(
    username: String, courseID: UUID, on db: any Database
) async throws -> CourseRole? {
    guard let user = try await APIUser.query(on: db).filter(\.$username == username).first() else {
        return nil
    }
    return try await APICourseEnrollment.query(on: db)
        .filter(\.$course.$id == courseID)
        .filter(\.$userID == user.requireID())
        .first()?.role
}

@Suite(.serialized, .timeLimit(.minutes(5))) final class AdminStaffProvisioningTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-admin-staff", authMode: .dual)
    }

    // MARK: - New-course form

    @Test func createWithUnknownInstructor_mintsAdoptablePlaceholder() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("staff_admin", on: app)
            let res = try await postForm(
                "/admin/courses", form: newCourseForm(code: "STF101", instructor: "new_prof"),
                cookie: cookie, formPath: "/admin/courses/new", on: app)
            #expect(res.status == .seeOther)

            let course = try #require(
                try await APICourse.query(on: app.db).filter(\.$code == "STF101").first())
            #expect(res.location == "/admin/courses/\(try course.requireID())")

            // The shape `adoptManuallyRegisteredStub` claims on first SSO login.
            let user = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "new_prof").first())
            #expect(user.authProvider == "duo-oidc")
            #expect(user.externalSubject == nil)
            #expect(user.passwordHash.isEmpty)
            #expect(user.role == UserRole.user.rawValue)
            #expect(
                try await enrollmentRole(username: "new_prof", courseID: course.requireID(), on: app.db)
                    == .instructor)

            let provisioned = try await APIAuditLogEntry.query(on: app.db)
                .filter(\.$action == AuditAction.userProvisioned.rawValue)
                .filter(\.$targetID == user.requireID().uuidString)
                .count()
            #expect(provisioned == 1, "the placeholder account is audited")
        }
    }

    @Test func createWithExistingInstructorByEmail_enrollsThatAccount() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("staff_admin", on: app)
            let existing = try await makeTestUser(on: app, username: "known_prof")
            existing.email = "known@example.com"
            try await existing.save(on: app.db)

            _ = try await postForm(
                "/admin/courses", form: newCourseForm(code: "STF102", instructor: "known@example.com"),
                cookie: cookie, formPath: "/admin/courses/new", on: app)

            let course = try #require(
                try await APICourse.query(on: app.db).filter(\.$code == "STF102").first())
            #expect(
                try await enrollmentRole(username: "known_prof", courseID: course.requireID(), on: app.db)
                    == .instructor)
            #expect(try await APIUser.query(on: app.db).filter(\.$username == "known@example.com").count() == 0)
        }
    }

    @Test func createWithoutInstructor_enrollsNobody() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("staff_admin", on: app)
            _ = try await postForm(
                "/admin/courses", form: newCourseForm(code: "STF103", instructor: "  "),
                cookie: cookie, formPath: "/admin/courses/new", on: app)

            let course = try #require(
                try await APICourse.query(on: app.db).filter(\.$code == "STF103").first())
            let enrollments = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$course.$id == course.requireID()).count()
            #expect(enrollments == 0)
        }
    }

    @Test(arguments: [
        ("nobody@example.com", CourseFormError.instructorEmail),
        ("bad name!", CourseFormError.instructorInvalid),
    ])
    func createWithRefusedInstructor_createsNoCourse(instructor: String, error: CourseFormError) async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("staff_admin", on: app)
            let res = try await postForm(
                "/admin/courses", form: newCourseForm(code: "STF104", instructor: instructor),
                cookie: cookie, formPath: "/admin/courses/new", on: app)

            #expect(res.location == "/admin/courses/new?error=\(error.rawValue)")
            #expect(try await APICourse.query(on: app.db).filter(\.$code == "STF104").count() == 0)
            #expect(try await APIUser.query(on: app.db).filter(\.$username == instructor).count() == 0)
        }
    }

    @Test func newCourseFormOffersTheInstructorField() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("staff_admin", on: app)
            let html = try await getHTML("/admin/courses/new", cookie: cookie, on: app)
            #expect(html.contains(#"name="instructor""#))
            #expect(html.contains("The person need not have signed in"))
        }
    }

    // MARK: - Course page staff form

    @Test func addStaff_unknownUser_mintsPlaceholderAtRole() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("staff_admin", on: app)
            let course = try await makeTestCourse(on: app, code: "STF201")
            let courseID = try course.requireID()

            let res = try await postForm(
                "/admin/courses/\(courseID)/staff", form: ["identifier": "new_ta", "role": "ta"],
                cookie: cookie, formPath: "/admin/courses/\(courseID)", on: app)

            #expect(res.location == "/admin/courses/\(courseID)?staffAdded=1")
            #expect(try await enrollmentRole(username: "new_ta", courseID: courseID, on: app.db) == .ta)
            let html = try await getHTML(try #require(res.location), cookie: cookie, on: app)
            #expect(html.contains("Staff member added."))
        }
    }

    @Test func addStaff_promotesAnEnrolledStudentInPlace() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("staff_admin", on: app)
            let course = try await makeTestCourse(on: app, code: "STF202")
            let courseID = try course.requireID()
            let student = try await makeTestUser(on: app, username: "promoted_stu")
            try await APICourseEnrollment(userID: student.requireID(), courseID: courseID, role: .student)
                .save(on: app.db)

            _ = try await postForm(
                "/admin/courses/\(courseID)/staff", form: ["identifier": "promoted_stu", "role": "instructor"],
                cookie: cookie, formPath: "/admin/courses/\(courseID)", on: app)

            let rows = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$course.$id == courseID)
                .filter(\.$userID == student.requireID())
                .all()
            #expect(rows.count == 1)
            #expect(rows.first?.role == .instructor)
        }
    }

    @Test(arguments: [
        (["identifier": "someone", "role": "student"], StaffFormError.role),
        (["identifier": "nobody@example.com", "role": "ta"], StaffFormError.email),
        (["identifier": "", "role": "ta"], StaffFormError.identifier),
    ])
    func addStaff_refusesAndShowsTheReason(form: [String: String], error: StaffFormError) async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("staff_admin", on: app)
            let course = try await makeTestCourse(on: app, code: "STF203")
            let courseID = try course.requireID()

            let res = try await postForm(
                "/admin/courses/\(courseID)/staff", form: form,
                cookie: cookie, formPath: "/admin/courses/\(courseID)", on: app)

            #expect(res.location == "/admin/courses/\(courseID)?staffError=\(error.rawValue)#add-staff-panel")
            let enrollments = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$course.$id == courseID).count()
            #expect(enrollments == 0)
            let html = try await getHTML(
                "/admin/courses/\(courseID)?staffError=\(error.rawValue)", cookie: cookie, on: app)
            #expect(html.contains(error.message.replacingOccurrences(of: "'", with: "&#39;")))
        }
    }

    @Test func addStaff_refusedForANonAdmin() async throws {
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "STF204")
            let courseID = try course.requireID()
            // A per-course instructor is not an admin: the admin area refuses them.
            let cookie = try await loginUser(username: "plain_prof", password: "pw", role: "user", on: app)
            let prof = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "plain_prof").first())
            try await APICourseEnrollment(userID: prof.requireID(), courseID: courseID, role: .instructor)
                .save(on: app.db)

            let res = try await postForm(
                "/admin/courses/\(courseID)/staff", form: ["identifier": "sneaky", "role": "ta"],
                cookie: cookie, formPath: "/", on: app)

            #expect(res.location != "/admin/courses/\(courseID)?staffAdded=1")
            #expect(try await APIUser.query(on: app.db).filter(\.$username == "sneaky").count() == 0)
        }
    }

    @Test func addStaff_refusedOnAnArchivedCourse() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("staff_admin", on: app)
            let course = try await makeTestCourse(on: app, code: "STF205")
            course.isArchived = true
            try await course.save(on: app.db)
            let courseID = try course.requireID()

            let res = try await postForm(
                "/admin/courses/\(courseID)/staff", form: ["identifier": "late_ta", "role": "ta"],
                cookie: cookie, formPath: "/admin/courses/\(courseID)", on: app)

            #expect(res.status == .conflict)
            #expect(try await APIUser.query(on: app.db).filter(\.$username == "late_ta").count() == 0)
        }
    }
}

/// Under local sign-in only, nothing can adopt a placeholder, so an admin can
/// add only a person who already has an account.
@Suite(.serialized, .timeLimit(.minutes(5))) final class AdminStaffProvisioningLocalSignInTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-admin-staff-local", authMode: .local)
    }

    @Test func createWithUnknownInstructor_isRefused() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("local_admin", on: app)
            let res = try await postForm(
                "/admin/courses", form: newCourseForm(code: "LOC101", instructor: "ghost_prof"),
                cookie: cookie, formPath: "/admin/courses/new", on: app)

            #expect(res.location == "/admin/courses/new?error=\(CourseFormError.instructorUnknown.rawValue)")
            #expect(try await APICourse.query(on: app.db).filter(\.$code == "LOC101").count() == 0)
            #expect(try await APIUser.query(on: app.db).filter(\.$username == "ghost_prof").count() == 0)
        }
    }

    @Test func addStaff_existingAccount_isEnrolled() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("local_admin", on: app)
            let course = try await makeTestCourse(on: app, code: "LOC102")
            let courseID = try course.requireID()
            _ = try await makeTestUser(on: app, username: "local_prof")

            let res = try await postForm(
                "/admin/courses/\(courseID)/staff", form: ["identifier": "local_prof", "role": "instructor"],
                cookie: cookie, formPath: "/admin/courses/\(courseID)", on: app)

            #expect(res.location == "/admin/courses/\(courseID)?staffAdded=1")
            #expect(try await enrollmentRole(username: "local_prof", courseID: courseID, on: app.db) == .instructor)
        }
    }

    @Test func addStaff_unknownUser_isRefused() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("local_admin", on: app)
            let course = try await makeTestCourse(on: app, code: "LOC103")
            let courseID = try course.requireID()

            let res = try await postForm(
                "/admin/courses/\(courseID)/staff", form: ["identifier": "ghost_ta", "role": "ta"],
                cookie: cookie, formPath: "/admin/courses/\(courseID)", on: app)

            #expect(
                res.location
                    == "/admin/courses/\(courseID)?staffError=\(StaffFormError.unknown.rawValue)#add-staff-panel")
            #expect(try await APIUser.query(on: app.db).filter(\.$username == "ghost_ta").count() == 0)
        }
    }
}
