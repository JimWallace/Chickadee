// Tests/APITests/AccountJoinCourseTests.swift
//
// `POST /account/enroll`: the "Join" button on the account page.
//
// A student may join an open course and nothing else. A closed course is
// instructor-managed (`CourseEnrollmentMode.closed`), and an archived course is
// over. The `/enroll` door has always applied this rule; this door did not, so
// a student who knew a closed course's ID could enroll in it.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2)))
final class AccountJoinCourseTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-account-join")
    }

    /// Posts the join form for `courseID` and returns the redirect target.
    private func join(courseID: String, cookie: String) async throws -> String? {
        let (token, bound) = try await csrfFields(for: "/account", cookie: cookie, on: app)
        var location: String?
        try await app.asyncTest(
            .POST, "/account/enroll",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: bound)
                try req.content.encode(["courseID": courseID, "_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
                #expect(res.status == .seeOther)
                location = res.headers.first(name: .location)
            })
        return location
    }

    private func enrollments(username: String, courseID: UUID) async throws -> [APICourseEnrollment] {
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first())
        return try await APICourseEnrollment.query(on: app.db)
            .filter(\.$userID == user.requireID())
            .filter(\.$course.$id == courseID)
            .all()
    }

    @Test func aStudentJoinsAnOpenCourseAsAStudent() async throws {
        try await withApp(app) { _ in
            let course = try await makeTestCourse(on: app, code: "OPEN1", mode: .open)
            let cookie = try await loginAsStudent("joiner", on: app)

            let location = try await join(courseID: try course.requireID().uuidString, cookie: cookie)

            #expect(location == "/account")
            let rows = try await enrollments(username: "joiner", courseID: try course.requireID())
            #expect(rows.map(\.role) == [.student])
        }
    }

    @Test func aStudentCannotJoinAClosedCourse() async throws {
        try await withApp(app) { _ in
            let course = try await makeTestCourse(on: app, code: "CLOSED1", mode: .closed)
            let cookie = try await loginAsStudent("intruder", on: app)

            let location = try await join(courseID: try course.requireID().uuidString, cookie: cookie)

            #expect(location == "/account?error=invalid")
            #expect(try await enrollments(username: "intruder", courseID: try course.requireID()).isEmpty)
        }
    }

    @Test func aStudentCannotJoinAnArchivedCourse() async throws {
        try await withApp(app) { _ in
            let course = try await makeTestCourse(on: app, code: "OLD1", archived: true, mode: .open)
            let cookie = try await loginAsStudent("latecomer", on: app)

            let location = try await join(courseID: try course.requireID().uuidString, cookie: cookie)

            #expect(location == "/account?error=invalid")
            #expect(try await enrollments(username: "latecomer", courseID: try course.requireID()).isEmpty)
        }
    }

    @Test func joiningTwiceKeepsOneEnrollment() async throws {
        try await withApp(app) { _ in
            let course = try await makeTestCourse(on: app, code: "OPEN2", mode: .open)
            let cookie = try await loginAsStudent("twice", on: app)
            let courseID = try course.requireID()

            _ = try await join(courseID: courseID.uuidString, cookie: cookie)
            _ = try await join(courseID: courseID.uuidString, cookie: cookie)

            #expect(try await enrollments(username: "twice", courseID: courseID).count == 1)
        }
    }

    @Test(arguments: ["", "not-a-uuid", UUID().uuidString])
    func aCourseIDThatNamesNoCourseIsRefused(courseID: String) async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent("guesser", on: app)

            let location = try await join(courseID: courseID, cookie: cookie)

            #expect(location == "/account?error=invalid")
        }
    }
}
