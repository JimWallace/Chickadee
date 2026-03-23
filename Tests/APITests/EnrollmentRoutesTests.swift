// Tests/APITests/EnrollmentRoutesTests.swift
//
// Integration tests for EnrollmentRoutes:
//   GET  /enroll                        — page lists open, non-archived courses
//   POST /enroll                        — saves selections, redirects
//   POST /courses/:courseID/activate    — sets active course in session

import XCTest
import XCTVapor
@testable import chickadee_server
import FluentSQLiteDriver
import Foundation

final class EnrollmentRoutesTests: XCTestCase {

    private var app: Application!
    private var tmpDir: String!

    override func setUp() async throws {
        app = Application(.testing)

        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-enr-\(UUID().uuidString)/")
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
        try await app.autoMigrate().get()
        configureLeaf(app)
        try routes(app)
    }

    override func tearDown() async throws {
        app.shutdown()
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    // MARK: - Helpers

    @discardableResult
    private func makeCourse(code: String, open: Bool = true, archived: Bool = false) async throws -> APICourse {
        let c = APICourse(code: code, name: "Course \(code)", openEnrollment: open)
        c.isArchived = archived
        try await c.save(on: app.db)
        return c
    }

    // MARK: - GET /enroll

    func testEnrollPage_showsOpenCourses() async throws {
        let open   = try await makeCourse(code: "ENR_OPEN1",   open: true)
        let closed = try await makeCourse(code: "ENR_CLOSED1", open: false)
        let archived = try await makeCourse(code: "ENR_ARCH1", open: true, archived: true)
        _ = closed; _ = archived  // suppress unused warnings

        let cookie = try await loginUser(username: "enr_student1", password: "pw",
                                         role: "student", on: app)
        try await app.test(.GET, "/enroll", beforeRequest: { req in
            req.headers.add(name: .cookie, value: cookie)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let html = res.body.string
            XCTAssertTrue(html.contains(open.code),   "Open course should appear")
            XCTAssertFalse(html.contains(closed.code),   "Closed course should not appear")
            XCTAssertFalse(html.contains(archived.code), "Archived course should not appear")
        })
    }

    func testEnrollPage_unauthenticated_redirects() async throws {
        try app.test(.GET, "/enroll") { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/login")
        }
    }

    // MARK: - POST /enroll

    func testSaveEnrollment_enrollsInSelectedCourses() async throws {
        let course = try await makeCourse(code: "ENR_SAVE1", open: true)
        let courseID = try course.requireID()
        let cookie = try await loginUser(username: "enr_student2", password: "pw",
                                         role: "student", on: app)

        let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)
        try await app.test(.POST, "/enroll", beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            req.headers.contentType = .urlEncodedForm
            req.body = .init(string: "courseIDs=\(courseID.uuidString)&_csrf=\(token)")
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            XCTAssertEqual(res.headers.first(name: .location), "/")
        })

        let user = try await APIUser.query(on: app.db).filter(\.$username == "enr_student2").first()
        let enrollments = try await APICourseEnrollment.query(on: app.db)
            .filter(\.$userID == user!.requireID())
            .all()
        XCTAssertEqual(enrollments.count, 1)
        XCTAssertEqual(enrollments.first?.$course.id, courseID)
    }

    func testSaveEnrollment_noneSelected_redirectsWithError() async throws {
        let cookie = try await loginUser(username: "enr_student3", password: "pw",
                                         role: "student", on: app)
        let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)

        try await app.test(.POST, "/enroll", beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            try req.content.encode(["_csrf": token], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
            let loc = res.headers.first(name: .location) ?? ""
            XCTAssertTrue(loc.contains("error=none_selected"),
                          "Should redirect with none_selected error, got: \(loc)")
        })
    }

    func testSaveEnrollment_ignoresClosedCourses() async throws {
        let closed = try await makeCourse(code: "ENR_CLOSED2", open: false)
        let closedID = try closed.requireID()
        let cookie = try await loginUser(username: "enr_student4", password: "pw",
                                         role: "student", on: app)
        let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)

        try await app.test(.POST, "/enroll", beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            req.headers.contentType = .urlEncodedForm
            req.body = .init(string: "courseIDs=\(closedID.uuidString)&_csrf=\(token)")
        }, afterResponse: { res in
            // closed course is not valid → same as none selected → error redirect
            XCTAssertEqual(res.status, .seeOther)
            let loc = res.headers.first(name: .location) ?? ""
            XCTAssertTrue(loc.contains("error=none_selected"))
        })

        let user = try await APIUser.query(on: app.db).filter(\.$username == "enr_student4").first()
        let enrollments = try await APICourseEnrollment.query(on: app.db)
            .filter(\.$userID == user!.requireID()).all()
        XCTAssertTrue(enrollments.isEmpty, "Should not be enrolled in a closed course")
    }

    func testSaveEnrollment_doesNotDuplicate() async throws {
        let course = try await makeCourse(code: "ENR_DUP1", open: true)
        let courseID = try course.requireID()
        let cookie = try await loginUser(username: "enr_student5", password: "pw",
                                         role: "student", on: app)

        // Enroll twice
        for _ in 0..<2 {
            let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)
            try await app.test(.POST, "/enroll", beforeRequest: { req in
                req.headers.add(name: .cookie, value: newCookie)
                req.headers.contentType = .urlEncodedForm
                req.body = .init(string: "courseIDs=\(courseID.uuidString)&_csrf=\(token)")
            }, afterResponse: { _ in })
        }

        let user = try await APIUser.query(on: app.db).filter(\.$username == "enr_student5").first()
        let enrollments = try await APICourseEnrollment.query(on: app.db)
            .filter(\.$userID == user!.requireID()).all()
        XCTAssertEqual(enrollments.count, 1, "Should not create duplicate enrollments")
    }

    // MARK: - POST /courses/:courseID/activate

    func testActivateCourse_enrolledUser_setsSession() async throws {
        let course = try await makeCourse(code: "ACT_COURSE1", open: true)
        let courseID = try course.requireID()
        // loginUser auto-enrolls the student because ACT_COURSE1 has openEnrollment=true
        // and it's the only course, so no need to manually create an enrollment.
        let cookie = try await loginUser(username: "act_student1", password: "pw",
                                         role: "student", on: app)

        let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)
        try await app.test(.POST, "/courses/\(courseID.uuidString)/activate", beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            try req.content.encode(["_csrf": token], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
        })
    }

    func testActivateCourse_notEnrolled_doesNotSetSession() async throws {
        let course = try await makeCourse(code: "ACT_COURSE2", open: true)
        let courseID = try course.requireID()
        let cookie = try await loginUser(username: "act_student2", password: "pw",
                                         role: "student", on: app)
        let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)

        // Not enrolled — should still redirect (silently ignored), just not set session
        try await app.test(.POST, "/courses/\(courseID.uuidString)/activate", beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            try req.content.encode(["_csrf": token], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .seeOther)
        })
    }

    func testActivateCourse_invalidCourseID_returns400() async throws {
        let cookie = try await loginUser(username: "act_student3", password: "pw",
                                         role: "student", on: app)
        let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)

        try await app.test(.POST, "/courses/not-a-uuid/activate", beforeRequest: { req in
            req.headers.add(name: .cookie, value: newCookie)
            try req.content.encode(["_csrf": token], as: .urlEncodedForm)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .badRequest)
        })
    }
}
