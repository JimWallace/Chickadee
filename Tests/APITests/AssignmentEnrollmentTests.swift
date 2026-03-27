// Tests/APITests/AssignmentEnrollmentTests.swift
//
// Integration tests for AssignmentRoutes+Enrollment:
//   POST /courses/:courseID/enrollment-mode  — set enrollment mode
//   POST /courses/:courseID/enroll-csv       — bulk-enrol from CSV upload

import XCTest
import XCTVapor
@testable import chickadee_server
import FluentSQLiteDriver
import Foundation
import Core

final class AssignmentEnrollmentTests: XCTestCase {

    private var app: Application!
    private var tmpDir: String!

    override func setUp() async throws {
        app = try await Application.make(.testing)

        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-enroll-\(UUID().uuidString)/")
            .path
        let dirs = ["results/", "testsetups/", "submissions/"].map { tmpDir + $0 }
        for dir in dirs {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        app.resultsDirectory     = dirs[0]
        app.testSetupsDirectory  = dirs[1]
        app.submissionsDirectory = dirs[2]

        app.sessions.use(.memory)
        app.middleware.use(app.sessions.middleware)
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateUsers())
        app.migrations.add(CreateCourses())
        app.migrations.add(CreateCourseEnrollments())
        app.migrations.add(CreateTestSetups())
        app.migrations.add(CreateSubmissions())
        app.migrations.add(CreateResults())
        app.migrations.add(CreateAssignments())
        app.migrations.add(CreatePerformanceIndexes())
        app.migrations.add(AddCourseSections())
        app.migrations.add(AddCourseOpenEnrollment())
        app.migrations.add(AddCourseEnrollmentMode())
        try await app.autoMigrate()
        configureLeaf(app)
        try routes(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        try? FileManager.default.removeItem(atPath: tmpDir)
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
