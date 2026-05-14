// Tests/APITests/AssignmentEnrollmentTests.swift
//
// Integration tests for AssignmentRoutes+Enrollment:
//   POST /courses/:courseID/enrollment-mode  — set enrollment mode
//   GET  /instructor/enroll-csv              — bulk-enrol upload form
//   POST /courses/:courseID/enroll-csv       — bulk-enrol from CSV upload

import XCTest
import XCTVapor
@testable import chickadee_server
import Fluent
import Foundation
import Core

final class AssignmentEnrollmentTests: XCTestCase {

    private var app: Application!
    override func setUp() async throws {
        app = try await makeTestApp(prefix: "chickadee-enroll")
    }

    override func tearDown() async throws {
        try await app.tearDownTestApp()
    }

    // MARK: - Helpers

    private func makeCourse(code: String,
                            mode: CourseEnrollmentMode = .closed) async throws -> APICourse {
        let course = APICourse(code: code, name: "Test \(code)", enrollmentMode: mode)
        try await course.save(on: app.db)
        return course
    }

    private func makeStudent(username: String) async throws -> APIUser {
        let hash = try Bcrypt.hash("pw")
        let user = APIUser(username: username, passwordHash: hash, role: "student")
        try await user.save(on: app.db)
        return user
    }

    private func enroll(user: APIUser, in course: APICourse) async throws {
        let enrollment = APICourseEnrollment(userID: try user.requireID(), courseID: try course.requireID())
        try await enrollment.save(on: app.db)
    }

    // MARK: - POST /courses/:courseID/enrollment-mode

    func testSetEnrollmentMode_instructorCanSetToOpen() async throws {
        let course = try await makeCourse(code: "OE_TOGGLE1", mode: .closed)
        let cookie = try await loginUser(username: "oe_instructor1", password: "pw",
                                         role: "instructor", on: app)
        let courseID = try course.requireID().uuidString
        let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/courses/\(courseID)/enrollment-mode", beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            try req.content.encode(["enrollmentMode": "open", "_csrf": token], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
        })

        let updated = try await APICourse.find(course.id, on: app.db)
        XCTAssertEqual(updated?.enrollmentMode, .open)
    }

    func testSetEnrollmentMode_instructorCanSetToClosed() async throws {
        let course = try await makeCourse(code: "OE_TOGGLE2", mode: .open)
        let cookie = try await loginUser(username: "oe_instructor2", password: "pw",
                                         role: "instructor", on: app)
        let courseID = try course.requireID().uuidString
        let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/courses/\(courseID)/enrollment-mode", beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            try req.content.encode(["enrollmentMode": "closed", "_csrf": token], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
        })

        let updated = try await APICourse.find(course.id, on: app.db)
        XCTAssertEqual(updated?.enrollmentMode, .closed)
    }

    func testSetEnrollmentMode_studentForbidden() async throws {
        let course = try await makeCourse(code: "OE_TOGGLE3")
        let cookie = try await loginUser(username: "oe_student1", password: "pw",
                                         role: "student", on: app)
        let courseID = try course.requireID().uuidString
        let (token, newCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/courses/\(courseID)/enrollment-mode", beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            try req.content.encode(["enrollmentMode": "open", "_csrf": token], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .forbidden)
        })
    }

    func testSetEnrollmentMode_notFound() async throws {
        let cookie = try await loginUser(username: "oe_instructor3", password: "pw",
                                         role: "instructor", on: app)
        let bogusID = UUID().uuidString
        let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/courses/\(bogusID)/enrollment-mode", beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            try req.content.encode(["enrollmentMode": "open", "_csrf": token], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .notFound)
        })
    }

    // MARK: - POST /courses/:courseID/enroll-csv

    func testEnrollCSVFormShowsDedicatedUploadPage() async throws {
        let course = try await makeCourse(code: "CSV_FORM1")
        let cookie = try await loginUser(username: "csv_instructor_form", password: "pw",
                                         role: "instructor", on: app)
        let instructorQueryResult = try await APIUser.query(on: app.db)
            .filter(\.$username == "csv_instructor_form")
            .first()
        let instructor = try XCTUnwrap(instructorQueryResult)
        try await enroll(user: instructor, in: course)
        let courseID = try course.requireID().uuidString

        try await app.asyncTest(.GET, "/instructor/enroll-csv", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            XCTAssertTrue(html.contains("Enrol from CSV"))
            XCTAssertTrue(html.contains("/courses/\(courseID)/enroll-csv"))
            XCTAssertTrue(html.contains("type=\"file\""))
            XCTAssertTrue(html.contains("Cancel"))
        })
    }

    func testBulkEnrollCSV_enrollsMatchedUsers() async throws {
        let course = try await makeCourse(code: "CSV_ENROLL1")
        _ = try await makeStudent(username: "csv_alice")
        _ = try await makeStudent(username: "csv_bob")
        let cookie = try await loginUser(username: "csv_instructor1", password: "pw",
                                         role: "instructor", on: app)
        let courseID = try course.requireID().uuidString
        let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)

        let csvData = "csv_alice\ncsv_bob\ncsv_notexist\n"

        try await app.asyncTest(.POST, "/courses/\(courseID)/enroll-csv", beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            var body = ByteBufferAllocator().buffer(capacity: 256)
            let boundary = "----TestBoundary"
            let csvBytes = Array(csvData.utf8)
            let part = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"users.csv\"\r\nContent-Type: text/csv\r\n\r\n\(csvData)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\n\(token)\r\n--\(boundary)--\r\n"
            _ = csvBytes  // suppress unused warning
            body.writeString(part)
            req.headers.contentType = HTTPMediaType(type: "multipart", subType: "form-data",
                                                    parameters: ["boundary": boundary])
            req.body = .init(buffer: body)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            // The result page shows enrolled count and notFound usernames
            XCTAssertTrue(html.contains("csv_notexist") || html.contains("2") || html.contains("enrolled"),
                          "Result page should report enrollment results")
        })

        let enrollments = try await APICourseEnrollment.query(on: app.db)
            .filter(\.$course.$id == course.requireID())
            .all()
        XCTAssertEqual(enrollments.count, 2, "Both existing users should be enrolled")
    }

    func testBulkEnrollCSV_skipsAlreadyEnrolled() async throws {
        let course = try await makeCourse(code: "CSV_ENROLL2")
        let student = try await makeStudent(username: "csv_charlie")
        // Pre-enroll charlie
        let enrollment = APICourseEnrollment(userID: try student.requireID(), courseID: try course.requireID())
        try await enrollment.save(on: app.db)

        let cookie = try await loginUser(username: "csv_instructor2", password: "pw",
                                         role: "instructor", on: app)
        let courseID = try course.requireID().uuidString
        let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)

        let csvData = "csv_charlie\n"
        let boundary = "----TestBoundary2"
        let part = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"users.csv\"\r\nContent-Type: text/csv\r\n\r\n\(csvData)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\n\(token)\r\n--\(boundary)--\r\n"

        try await app.asyncTest(.POST, "/courses/\(courseID)/enroll-csv", beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            var body = ByteBufferAllocator().buffer(capacity: 256)
            body.writeString(part)
            req.headers.contentType = HTTPMediaType(type: "multipart", subType: "form-data",
                                                    parameters: ["boundary": boundary])
            req.body = .init(buffer: body)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })

        let enrollments = try await APICourseEnrollment.query(on: app.db)
            .filter(\.$course.$id == course.requireID())
            .all()
        XCTAssertEqual(enrollments.count, 1, "Should still be exactly one enrollment (no duplicate)")
    }

    // MARK: - Pre-enrollment (no APIUser yet)

    func testBulkEnrollCSV_recordsPreEnrollmentForUnknownUsernames() async throws {
        let course = try await makeCourse(code: "CSV_PRE1")
        // alice exists; carol does not
        _ = try await makeStudent(username: "csv_pre_alice")
        let cookie = try await loginUser(username: "csv_pre_instructor1", password: "pw",
                                         role: "instructor", on: app)
        let courseID = try course.requireID().uuidString
        let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)

        let csvData = "csv_pre_alice\ncsv_pre_carol\n"
        let boundary = "----TestBoundaryPre1"
        let part = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"u.csv\"\r\nContent-Type: text/csv\r\n\r\n\(csvData)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\n\(token)\r\n--\(boundary)--\r\n"

        try await app.asyncTest(.POST, "/courses/\(courseID)/enroll-csv", beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            var body = ByteBufferAllocator().buffer(capacity: 256)
            body.writeString(part)
            req.headers.contentType = HTTPMediaType(type: "multipart", subType: "form-data",
                                                    parameters: ["boundary": boundary])
            req.body = .init(buffer: body)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })

        // alice was enrolled directly.
        let enrollments = try await APICourseEnrollment.query(on: app.db)
            .filter(\.$course.$id == course.requireID())
            .all()
        XCTAssertEqual(enrollments.count, 1)

        // carol got recorded as a pre-enrollment.
        let preEnrollments = try await APIPreEnrollment.query(on: app.db)
            .filter(\.$course.$id == course.requireID())
            .all()
        XCTAssertEqual(preEnrollments.count, 1)
        XCTAssertEqual(preEnrollments.first?.username, "csv_pre_carol")
    }

    func testResolvePendingPreEnrollments_promotesPendingToActiveOnLogin() async throws {
        let course = try await makeCourse(code: "CSV_PRE2")
        let courseID = try course.requireID()

        // Pre-enroll a username that has no APIUser yet.
        let pending = APIPreEnrollment(courseID: courseID, username: "csv_pre_promote")
        try await pending.save(on: app.db)

        // The student then logs in (we just create the user directly here
        // because the resolver doesn't care HOW the APIUser came to exist).
        let user = try await makeStudent(username: "csv_pre_promote")
        await resolvePendingPreEnrollments(for: user, db: app.db, logger: app.logger)

        // The pending row is gone, replaced by a real enrollment.
        let remainingPending = try await APIPreEnrollment.query(on: app.db)
            .filter(\.$username == "csv_pre_promote")
            .count()
        XCTAssertEqual(remainingPending, 0)

        let enrollments = try await APICourseEnrollment.query(on: app.db)
            .filter(\.$course.$id == courseID)
            .filter(\.$userID == user.requireID())
            .count()
        XCTAssertEqual(enrollments, 1)
    }

    func testResolvePendingPreEnrollments_isIdempotent() async throws {
        let course = try await makeCourse(code: "CSV_PRE3")
        let courseID = try course.requireID()

        let pending = APIPreEnrollment(courseID: courseID, username: "csv_pre_idem")
        try await pending.save(on: app.db)

        let user = try await makeStudent(username: "csv_pre_idem")
        // Run the resolver twice — second call should not duplicate
        // enrollments and should not throw.
        await resolvePendingPreEnrollments(for: user, db: app.db, logger: app.logger)
        await resolvePendingPreEnrollments(for: user, db: app.db, logger: app.logger)

        let enrollments = try await APICourseEnrollment.query(on: app.db)
            .filter(\.$course.$id == courseID)
            .filter(\.$userID == user.requireID())
            .count()
        XCTAssertEqual(enrollments, 1)
    }

    func testBulkEnrollCSV_isIdempotentOnReupload() async throws {
        let course = try await makeCourse(code: "CSV_PRE4")
        let cookie = try await loginUser(username: "csv_pre_instructor4", password: "pw",
                                         role: "instructor", on: app)
        let courseID = try course.requireID().uuidString
        let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)

        let csvData = "csv_pre_dup\n"
        let boundary = "----TestBoundaryPre4"

        func upload(cookie: String, token: String) async throws {
            let part = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"u.csv\"\r\nContent-Type: text/csv\r\n\r\n\(csvData)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\n\(token)\r\n--\(boundary)--\r\n"
            try await app.asyncTest(.POST, "/courses/\(courseID)/enroll-csv", beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                var body = ByteBufferAllocator().buffer(capacity: 256)
                body.writeString(part)
                req.headers.contentType = HTTPMediaType(type: "multipart", subType: "form-data",
                                                        parameters: ["boundary": boundary])
                req.body = .init(buffer: body)
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
            })
        }

        try await upload(cookie: newCookie, token: token)
        try await upload(cookie: newCookie, token: token)

        let preEnrollments = try await APIPreEnrollment.query(on: app.db)
            .filter(\.$course.$id == course.requireID())
            .all()
        XCTAssertEqual(preEnrollments.count, 1, "Re-uploading should not create a duplicate pre_enrollment")
    }

    func testPreUnenroll_removesPendingRow() async throws {
        let course = try await makeCourse(code: "CSV_PRE5")
        let courseID = try course.requireID()

        // Pre-create a pending row.
        let pending = APIPreEnrollment(courseID: courseID, username: "csv_pre_cancel")
        try await pending.save(on: app.db)
        let preID = try pending.requireID().uuidString

        let cookie = try await loginUser(username: "csv_pre_instructor5", password: "pw",
                                         role: "instructor", on: app)
        let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/courses/\(courseID.uuidString)/pre-unenroll/\(preID)", beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            try req.content.encode(["_csrf": token], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
        })

        let pendingID = try pending.requireID()
        let remaining = try await APIPreEnrollment.query(on: app.db)
            .filter(\.$id == pendingID)
            .count()
        XCTAssertEqual(remaining, 0)
    }

    func testPreUnenroll_studentForbidden() async throws {
        let course = try await makeCourse(code: "CSV_PRE6")
        let courseID = try course.requireID()

        let pending = APIPreEnrollment(courseID: courseID, username: "csv_pre_studentforbidden")
        try await pending.save(on: app.db)
        let preID = try pending.requireID().uuidString

        let cookie = try await loginUser(username: "csv_pre_student6", password: "pw",
                                         role: "student", on: app)
        let (token, newCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)

        try await app.asyncTest(.POST, "/courses/\(courseID.uuidString)/pre-unenroll/\(preID)", beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            try req.content.encode(["_csrf": token], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .forbidden)
        })

        // Pending row still exists.
        let pendingID = try pending.requireID()
        let remaining = try await APIPreEnrollment.query(on: app.db)
            .filter(\.$id == pendingID)
            .count()
        XCTAssertEqual(remaining, 1)
    }

    func testBulkEnrollCSV_studentForbidden() async throws {
        let course = try await makeCourse(code: "CSV_ENROLL3")
        let cookie = try await loginUser(username: "csv_student1", password: "pw",
                                         role: "student", on: app)
        let courseID = try course.requireID().uuidString
        let (token, newCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)

        let boundary = "----TestBoundary3"
        let part = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"u.csv\"\r\nContent-Type: text/csv\r\n\r\nalice\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\n\(token)\r\n--\(boundary)--\r\n"

        try await app.asyncTest(.POST, "/courses/\(courseID)/enroll-csv", beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            var body = ByteBufferAllocator().buffer(capacity: 256)
            body.writeString(part)
            req.headers.contentType = HTTPMediaType(type: "multipart", subType: "form-data",
                                                    parameters: ["boundary": boundary])
            req.body = .init(buffer: body)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .forbidden)
        })
    }
}
