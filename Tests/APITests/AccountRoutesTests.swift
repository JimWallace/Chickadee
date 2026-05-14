// Tests/APITests/AccountRoutesTests.swift
//
// Integration tests for AccountRoutes:
//   POST /account/unenroll/:courseID   — leave a course
//
// Key behaviours under test:
//   - Only open-mode courses can be self-left (closed and auto return 403)
//   - Leaving does NOT delete submissions
//   - Unauthenticated access redirects to /login
//   - Invalid course ID returns 400; unknown ID returns 404

import Core
import Crypto
import Fluent
import Foundation
import XCTVapor
import XCTest

@testable import chickadee_server

final class AccountRoutesTests: XCTestCase {

    private var app: Application!
    override func setUp() async throws {
        app = try await makeTestApp(prefix: "chickadee-acct")
    }

    override func tearDown() async throws {
        try await app.tearDownTestApp()
    }

    // MARK: - Helpers

    private func makeCourse(
        code: String,
        mode: CourseEnrollmentMode = .open
    ) async throws -> APICourse {
        let c = APICourse(code: code, name: "Course \(code)", enrollmentMode: mode)
        try await c.save(on: app.db)
        return c
    }

    private func makeStudent(username: String) async throws -> APIUser {
        let hash = try Bcrypt.hash("pw")
        let user = APIUser(username: username, passwordHash: hash, role: "student")
        try await user.save(on: app.db)
        return user
    }

    private func enroll(user: APIUser, in course: APICourse) async throws {
        let e = APICourseEnrollment(userID: try user.requireID(), courseID: try course.requireID())
        try await e.save(on: app.db)
    }

    private func enrollmentCount(user: APIUser, in course: APICourse) async throws -> Int {
        try await APICourseEnrollment.query(on: app.db)
            .filter(\.$userID == user.requireID())
            .filter(\.$course.$id == course.requireID())
            .count()
    }

    // MARK: - Unauthenticated access

    func testLeaveCourse_unauthenticated_redirectsToLogin() async throws {
        let course = try await makeCourse(code: "UNAUTH_LEAVE")
        let courseID = try course.requireID().uuidString
        try await app.asyncTest(.POST, "/account/unenroll/\(courseID)") { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/login")
        }
    }

    // MARK: - Invalid / missing course

    func testLeaveCourse_invalidCourseID_returns400() async throws {
        let cookie = try await loginUser(
            username: "leave_bad_id", password: "pw",
            role: "student", on: app)
        let (token, newCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)
        try await app.asyncTest(
            .POST, "/account/unenroll/not-a-uuid",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: newCookie)
                try req.content.encode(["_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .badRequest)
            })
    }

    func testLeaveCourse_unknownCourseID_returns404() async throws {
        let cookie = try await loginUser(
            username: "leave_unknown", password: "pw",
            role: "student", on: app)
        let (token, newCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)
        let bogus = UUID().uuidString
        try await app.asyncTest(
            .POST, "/account/unenroll/\(bogus)",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: newCookie)
                try req.content.encode(["_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .notFound)
            })
    }

    // MARK: - Mode enforcement

    func testLeaveCourse_openMode_removesEnrollment() async throws {
        let course = try await makeCourse(code: "LEAVE_OPEN", mode: .open)
        let student = try await makeStudent(username: "leave_open_s1")
        try await enroll(user: student, in: course)

        let cookie = try await loginUser(
            username: "leave_open_s1", password: "pw",
            role: "student", on: app)
        let courseID = try course.requireID().uuidString
        let (token, newCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)

        try await app.asyncTest(
            .POST, "/account/unenroll/\(courseID)",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: newCookie)
                try req.content.encode(["_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
            })

        let count = try await enrollmentCount(user: student, in: course)
        XCTAssertEqual(count, 0, "Enrollment should be removed after leaving an open course")
    }

    func testLeaveCourse_closedMode_returns403() async throws {
        let course = try await makeCourse(code: "LEAVE_CLOSED", mode: .closed)
        let student = try await makeStudent(username: "leave_closed_s1")
        try await enroll(user: student, in: course)

        let cookie = try await loginUser(
            username: "leave_closed_s1", password: "pw",
            role: "student", on: app)
        let courseID = try course.requireID().uuidString
        let (token, newCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)

        try await app.asyncTest(
            .POST, "/account/unenroll/\(courseID)",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: newCookie)
                try req.content.encode(["_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
                XCTAssertEqual(
                    res.status, .forbidden,
                    "Closed-mode course: student should not be able to self-leave")
            })

        let count = try await enrollmentCount(user: student, in: course)
        XCTAssertEqual(count, 1, "Enrollment should remain after forbidden leave attempt")
    }

    func testLeaveCourse_autoMode_returns403() async throws {
        let course = try await makeCourse(code: "LEAVE_AUTO", mode: .auto)
        let student = try await makeStudent(username: "leave_auto_s1")
        try await enroll(user: student, in: course)

        let cookie = try await loginUser(
            username: "leave_auto_s1", password: "pw",
            role: "student", on: app)
        let courseID = try course.requireID().uuidString
        let (token, newCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)

        try await app.asyncTest(
            .POST, "/account/unenroll/\(courseID)",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: newCookie)
                try req.content.encode(["_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
                XCTAssertEqual(
                    res.status, .forbidden,
                    "Auto-mode course: student should not be able to self-leave")
            })

        let count = try await enrollmentCount(user: student, in: course)
        XCTAssertEqual(count, 1, "Enrollment should remain after forbidden leave attempt")
    }

    // MARK: - Submissions preserved

    func testLeaveCourse_preservesSubmissions() async throws {
        // Create a course and a test setup so we can create a submission.
        let course = try await makeCourse(code: "LEAVE_SUBS", mode: .open)
        let student = try await makeStudent(username: "leave_subs_s1")
        try await enroll(user: student, in: course)

        // Create a minimal test setup and submission record.
        let setupID = UUID().uuidString
        let zipPath = app.testSetupsDirectory + "\(setupID).zip"
        try Data("PK".utf8).write(to: URL(fileURLWithPath: zipPath))
        let manifest = """
            {"schemaVersion":1,"testSuites":[{"tier":"public","script":"t.sh"}],"timeLimitSeconds":5}
            """
        let setup = APITestSetup(
            id: setupID, manifest: manifest, zipPath: zipPath,
            courseID: try course.requireID())
        try await setup.save(on: app.db)

        let subID = UUID().uuidString
        let subZip = app.submissionsDirectory + "\(subID).zip"
        try Data("PK".utf8).write(to: URL(fileURLWithPath: subZip))
        let sub = APISubmission(
            id: subID, testSetupID: setupID, zipPath: subZip,
            attemptNumber: 1, status: "complete",
            filename: "sub.zip", userID: try student.requireID(),
            kind: APISubmission.Kind.student)
        try await sub.save(on: app.db)

        // Now leave the course.
        let cookie = try await loginUser(
            username: "leave_subs_s1", password: "pw",
            role: "student", on: app)
        let courseID = try course.requireID().uuidString
        let (token, newCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)
        try await app.asyncTest(
            .POST, "/account/unenroll/\(courseID)",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: newCookie)
                try req.content.encode(["_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
                XCTAssertEqual(res.status, .seeOther)
            })

        // Enrollment removed.
        let enrollCount = try await enrollmentCount(user: student, in: course)
        XCTAssertEqual(enrollCount, 0, "Enrollment should be removed")

        // Submission still exists.
        let subStillExists = try await APISubmission.find(subID, on: app.db)
        XCTAssertNotNil(subStillExists, "Submission must not be deleted when leaving a course")
    }
}
