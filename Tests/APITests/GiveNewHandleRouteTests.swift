// Tests/APITests/GiveNewHandleRouteTests.swift
//
// The staff "Give new handle" action on the instructor Students tab
// (POST /courses/:courseID/new-handle/:userID).  It is the only way a stored
// handle changes: a word-list change renames nobody (docs/student-avatars.md
// §3), so this is how a handle that must go is replaced.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class GiveNewHandleRouteTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-new-handle")
    }

    /// An instructor of the course, logged in. Returns the session cookie.
    private func loginInstructor(_ username: String, in course: APICourse) async throws -> String {
        let cookie = try await loginUser(username: username, password: "pw", role: "instructor", on: app)
        let user = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == username).first())
        try await APICourseEnrollment(
            userID: try user.requireID(), courseID: try course.requireID(), role: .instructor
        ).save(on: app.db)
        return cookie
    }

    /// A student enrolled in `course` whose stored handle is `handle`.
    private func enrolledStudent(
        _ username: String, in course: APICourse, handle: String
    ) async throws -> APICourseEnrollment {
        let student = try await makeTestStudent(on: app, username: username)
        let enrollment = try await makeTestEnrollment(
            on: app, userID: try student.requireID(), courseID: try course.requireID())
        enrollment.avatarHandle = handle
        try await enrollment.save(on: app.db)
        return enrollment
    }

    private func postNewHandle(
        course: APICourse, userID: UUID, cookie: String
    ) async throws -> HTTPStatus {
        let (token, newCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)
        var status: HTTPStatus = .internalServerError
        try await app.asyncTest(
            .POST, "/courses/\(try course.requireID().uuidString)/new-handle/\(userID.uuidString)",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: newCookie)
                try req.content.encode(["_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in status = res.status })
        return status
    }

    @Test func instructorGivesAStudentANewHandleAndItIsAudited() async throws {
        try await withApp(app) { _ in
            let course = try await makeTestCourse(on: app, code: "NH1")
            let enrollment = try await enrolledStudent("nh_student1", in: course, handle: "Quiet Cedar")
            let cookie = try await loginInstructor("nh_instructor1", in: course)

            let status = try await postNewHandle(course: course, userID: enrollment.userID, cookie: cookie)
            #expect(status == .seeOther)

            let stored = try #require(
                try await APICourseEnrollment.find(enrollment.id, on: app.db)?.avatarHandle)
            #expect(stored != "Quiet Cedar")
            #expect(AvatarHandle.isWellFormed(stored))

            let entry = try #require(
                try await APIAuditLogEntry.query(on: app.db)
                    .filter(\.$action == AuditAction.enrollmentHandleChanged.rawValue)
                    .first())
            #expect(entry.targetID == enrollment.userID.uuidString)

            // The redirect's banner names the student and the new handle, read
            // from the database: the table itself has no handle column.
            try await app.asyncTest(
                .GET, "/instructor/students?handleChanged=\(enrollment.userID.uuidString)",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.body.string.contains("@nh_student1 now has the class handle \(stored)."))
                })
        }
    }

    @Test func aStudentCannotChangeAHandle() async throws {
        try await withApp(app) { _ in
            let course = try await makeTestCourse(on: app, code: "NH2")
            let enrollment = try await enrolledStudent("nh_student2", in: course, handle: "Quiet Cedar")
            let cookie = try await loginUser(username: "nh_other2", password: "pw", role: "student", on: app)
            let other = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "nh_other2").first())
            _ = try await makeTestEnrollment(
                on: app, userID: try other.requireID(), courseID: try course.requireID())

            let status = try await postNewHandle(course: course, userID: enrollment.userID, cookie: cookie)
            #expect(status == .forbidden)

            let stored = try await APICourseEnrollment.find(enrollment.id, on: app.db)?.avatarHandle
            #expect(stored == "Quiet Cedar")
        }
    }

    @Test func theStudentsTabOffersTheAction() async throws {
        try await withApp(app) { _ in
            let course = try await makeTestCourse(on: app, code: "NH3")
            let enrollment = try await enrolledStudent("nh_student3", in: course, handle: "Hazy Cedar")
            let cookie = try await loginInstructor("nh_instructor3", in: course)

            try await app.asyncTest(
                .GET, "/instructor/students",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("Give new handle"))
                    #expect(html.contains("/new-handle/\(enrollment.userID.uuidString)"))
                })
        }
    }
}
