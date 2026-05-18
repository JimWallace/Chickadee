// Tests/APITests/EnrollmentRoutesTests.swift
//
// Integration tests for EnrollmentRoutes:
//   GET  /enroll                        — page lists open courses only
//   POST /enroll                        — saves selections, redirects
//   POST /courses/:courseID/activate    — sets active course in session
//
// Also covers auto-enrolment logic (resolveActiveCourse and postLoginRedirect)
// triggered by CourseEnrollmentMode.auto courses.

import Core
import Crypto
import Fluent
import Foundation
import Testing
import XCTVapor

@testable import chickadee_server

@Suite(.serialized) final class EnrollmentRoutesTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-enr")
    }

    // MARK: - Helpers

    @discardableResult
    private func makeCourse(
        code: String,
        mode: CourseEnrollmentMode = .open,
        archived: Bool = false
    ) async throws -> APICourse {
        let c = APICourse(code: code, name: "Course \(code)", enrollmentMode: mode)
        c.isArchived = archived
        try await c.save(on: app.db)
        return c
    }

    // MARK: - GET /enroll

    @Test func enrollPage_showsOnlyOpenCourses() async throws {
        try await withApp(app) { _ in
            let open = try await makeCourse(code: "ENR_OPEN1", mode: .open)
            let auto = try await makeCourse(code: "ENR_AUTO1", mode: .auto)
            let closed = try await makeCourse(code: "ENR_CLOSED1", mode: .closed)
            let archived = try await makeCourse(code: "ENR_ARCH1", mode: .open, archived: true)
            _ = auto; _ = closed; _ = archived

            let cookie = try await loginUser(
                username: "enr_student1", password: "pw",
                role: "student", on: app)
            try await app.asyncTest(
                .GET, "/enroll",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains(open.code), "Open course should appear")
                    #expect(html.contains(auto.code) == false, "Auto course should not appear on /enroll")
                    #expect(html.contains(closed.code) == false, "Closed course should not appear")
                    #expect(html.contains(archived.code) == false, "Archived course should not appear")
                })

        }
    }

    @Test func enrollPage_unauthenticated_redirects() async throws {
        try await withApp(app) { _ in
            try await app.asyncTest(.GET, "/enroll") { res in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "/login")
            }

        }
    }

    // MARK: - POST /enroll

    @Test func saveEnrollment_enrollsInSelectedCourses() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "ENR_SAVE1", mode: .open)
            let courseID = try course.requireID()
            let cookie = try await loginUser(
                username: "enr_student2", password: "pw",
                role: "student", on: app)

            let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/enroll",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    req.headers.contentType = .urlEncodedForm
                    req.body = .init(string: "courseIDs=\(courseID.uuidString)&_csrf=\(token)")
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/")
                })

            let user = try await APIUser.query(on: app.db).filter(\.$username == "enr_student2").first()
            let enrollments = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$userID == user!.requireID())
                .all()
            #expect(enrollments.count == 1)
            #expect(enrollments.first?.$course.id == courseID)

        }
    }

    @Test func saveEnrollment_noneSelected_redirectsWithError() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "enr_student3", password: "pw",
                role: "student", on: app)
            let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/enroll",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    let loc = res.headers.first(name: .location) ?? ""
                    #expect(
                        loc.contains("error=none_selected"),
                        "Should redirect with none_selected error, got: \(loc)")
                })

        }
    }

    @Test func saveEnrollment_ignoresClosedCourse() async throws {
        try await withApp(app) { _ in
            let closed = try await makeCourse(code: "ENR_CLOSED2", mode: .closed)
            let closedID = try closed.requireID()
            let cookie = try await loginUser(
                username: "enr_student4", password: "pw",
                role: "student", on: app)
            let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/enroll",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    req.headers.contentType = .urlEncodedForm
                    req.body = .init(string: "courseIDs=\(closedID.uuidString)&_csrf=\(token)")
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    let loc = res.headers.first(name: .location) ?? ""
                    #expect(loc.contains("error=none_selected"))
                })

            let user = try await APIUser.query(on: app.db).filter(\.$username == "enr_student4").first()
            let enrollments = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$userID == user!.requireID()).all()
            #expect(enrollments.isEmpty, "Should not be enrolled in a closed course")

        }
    }

    @Test func saveEnrollment_ignoresAutoCourse() async throws {
        try await withApp(app) { _ in
            // Auto courses are not shown on /enroll and must not be self-enrollable via POST.
            let auto = try await makeCourse(code: "ENR_AUTO2", mode: .auto)
            let autoID = try auto.requireID()
            // Create an open course so we can load a CSRF token from /enroll.
            try await makeCourse(code: "ENR_OPENFORCSRF1", mode: .open)

            let cookie = try await loginUser(
                username: "enr_student_auto", password: "pw",
                role: "student", on: app)

            let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/enroll",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    req.headers.contentType = .urlEncodedForm
                    req.body = .init(string: "courseIDs=\(autoID.uuidString)&_csrf=\(token)")
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    let loc = res.headers.first(name: .location) ?? ""
                    #expect(
                        loc.contains("error=none_selected"),
                        "Auto course should not be self-enrollable via /enroll, got: \(loc)")
                })

        }
    }

    @Test func saveEnrollment_doesNotDuplicate() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "ENR_DUP1", mode: .open)
            let courseID = try course.requireID()
            let cookie = try await loginUser(
                username: "enr_student5", password: "pw",
                role: "student", on: app)

            // Enroll twice
            for _ in 0..<2 {
                let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)
                try await app.asyncTest(
                    .POST, "/enroll",
                    beforeRequest: { req in
                        req.headers.add(name: .cookie, value: newCookie)
                        req.headers.contentType = .urlEncodedForm
                        req.body = .init(string: "courseIDs=\(courseID.uuidString)&_csrf=\(token)")
                    }, afterResponse: { _ in })
            }

            let user = try await APIUser.query(on: app.db).filter(\.$username == "enr_student5").first()
            let enrollments = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$userID == user!.requireID()).all()
            #expect(enrollments.count == 1, "Should not create duplicate enrollments")

        }
    }

    // MARK: - Auto-enrolment (resolveActiveCourse)

    @Test func autoEnroll_onResolveActiveCourse_enrollsInAutoCourse() async throws {
        try await withApp(app) { _ in
            let auto = try await makeCourse(code: "AUT_RESOLVE1", mode: .auto)
            let autoID = try auto.requireID()

            // loginUser triggers resolveActiveCourse which should auto-enrol.
            let cookie = try await loginUser(
                username: "aut_student1", password: "pw",
                role: "student", on: app)

            let user = try await APIUser.query(on: app.db).filter(\.$username == "aut_student1").first()
            let enrollments = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$userID == user!.requireID())
                .all()
            #expect(enrollments.count == 1)
            #expect(enrollments.first?.$course.id == autoID)
            _ = cookie

        }
    }

    @Test func autoEnroll_multipleAutoCourses_enrollsAll() async throws {
        try await withApp(app) { _ in
            let a1 = try await makeCourse(code: "AUT_MULTI1", mode: .auto)
            let a2 = try await makeCourse(code: "AUT_MULTI2", mode: .auto)
            let id1 = try a1.requireID()
            let id2 = try a2.requireID()

            let cookie = try await loginUser(
                username: "aut_multi_student", password: "pw",
                role: "student", on: app)

            let user = try await APIUser.query(on: app.db)
                .filter(\.$username == "aut_multi_student").first()
            let enrolledIDs = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$userID == user!.requireID())
                .all()
                .map { $0.$course.id }

            #expect(enrolledIDs.contains(id1), "Should be enrolled in first auto course")
            #expect(enrolledIDs.contains(id2), "Should be enrolled in second auto course")
            _ = cookie

        }
    }

    @Test func autoEnroll_doesNotEnrollInOpenOrClosedCourses() async throws {
        try await withApp(app) { _ in
            let open = try await makeCourse(code: "AUT_OPEN1", mode: .open)
            let closed = try await makeCourse(code: "AUT_CLOSED1", mode: .closed)
            let auto = try await makeCourse(code: "AUT_AUTO1", mode: .auto)
            let autoID = try auto.requireID()
            let openID = try open.requireID()
            let closedID = try closed.requireID()

            let cookie = try await loginUser(
                username: "aut_selectivity_student", password: "pw",
                role: "student", on: app)

            let user = try await APIUser.query(on: app.db)
                .filter(\.$username == "aut_selectivity_student").first()
            let enrolledIDs = Set(
                try await APICourseEnrollment.query(on: app.db)
                    .filter(\.$userID == user!.requireID())
                    .all()
                    .map { $0.$course.id })

            #expect(enrolledIDs.contains(autoID), "Should be auto-enrolled in .auto course")
            #expect(enrolledIDs.contains(openID) == false, "Should NOT be auto-enrolled in .open course")
            #expect(enrolledIDs.contains(closedID) == false, "Should NOT be auto-enrolled in .closed course")
            _ = cookie

        }
    }

    @Test func autoEnroll_doesNotDuplicateExistingEnrollment() async throws {
        try await withApp(app) { _ in
            let auto = try await makeCourse(code: "AUT_NODUP1", mode: .auto)
            let autoID = try auto.requireID()

            // Login twice — second visit should not create a duplicate enrollment.
            for _ in 0..<2 {
                _ = try await loginUser(
                    username: "aut_nodup_student", password: "pw",
                    role: "student", on: app)
            }

            let user = try await APIUser.query(on: app.db)
                .filter(\.$username == "aut_nodup_student").first()
            let count = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$userID == user!.requireID())
                .filter(\.$course.$id == autoID)
                .count()
            #expect(count == 1, "Should not create duplicate enrollment on repeated login")

        }
    }

    // MARK: - postLoginRedirect behaviour

    @Test func postLoginRedirect_withClosedCourseOnly_redirectsToHome() async throws {
        try await withApp(app) { _ in
            // Only a closed course → user can't self-enroll → redirect to / (empty state).
            try await makeCourse(code: "PLR_CLOSED1", mode: .closed)

            let u = APIUser(
                username: "plr_closed_student",
                passwordHash: try Bcrypt.hash("pw"), role: "student")
            try await u.save(on: app.db)

            let (csrf, cookie) = try await csrfFields(for: "/login", on: app)
            try await app.asyncTest(
                .POST, "/login",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    req.headers.contentType = .urlEncodedForm
                    req.body = .init(string: "username=plr_closed_student&password=pw&_csrf=\(csrf)")
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/", "User with only closed course should go to /")
                })

        }
    }

    @Test func postLoginRedirect_withOpenCourseOnly_redirectsToEnroll() async throws {
        try await withApp(app) { _ in
            // Only an open course → user has no enrollment → redirect to /enroll.
            try await makeCourse(code: "PLR_OPEN1", mode: .open)

            let u = APIUser(
                username: "plr_open_student",
                passwordHash: try Bcrypt.hash("pw"), role: "student")
            try await u.save(on: app.db)

            let (csrf, cookie) = try await csrfFields(for: "/login", on: app)
            try await app.asyncTest(
                .POST, "/login",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    req.headers.contentType = .urlEncodedForm
                    req.body = .init(string: "username=plr_open_student&password=pw&_csrf=\(csrf)")
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(
                        res.headers.first(name: .location) == "/enroll",
                        "User with open course and no enrollments should go to /enroll")
                })

        }
    }

    @Test func postLoginRedirect_withAutoCourse_enrollsAndRedirectsToHome() async throws {
        try await withApp(app) { _ in
            // Auto course → user gets enrolled → redirect to /.
            try await makeCourse(code: "PLR_AUTO1", mode: .auto)

            let u = APIUser(
                username: "plr_auto_student",
                passwordHash: try Bcrypt.hash("pw"), role: "student")
            try await u.save(on: app.db)
            let userID = try u.requireID()

            let (csrf, cookie) = try await csrfFields(for: "/login", on: app)
            try await app.asyncTest(
                .POST, "/login",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    req.headers.contentType = .urlEncodedForm
                    req.body = .init(string: "username=plr_auto_student&password=pw&_csrf=\(csrf)")
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/", "Auto-enrolled user should go to /")
                })

            let count = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$userID == userID)
                .count()
            #expect(count == 1, "User should be enrolled in the auto course after login")

        }
    }

    // MARK: - POST /courses/:courseID/activate

    @Test func activateCourse_enrolledUser_setsSession() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "ACT_COURSE1", mode: .auto)
            let courseID = try course.requireID()
            // auto mode: loginUser triggers auto-enrolment, so the student is enrolled.
            let cookie = try await loginUser(
                username: "act_student1", password: "pw",
                role: "student", on: app)

            let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/courses/\(courseID.uuidString)/activate",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

        }
    }

    @Test func activateCourse_notEnrolled_doesNotSetSession() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "ACT_COURSE2", mode: .open)
            let courseID = try course.requireID()
            let cookie = try await loginUser(
                username: "act_student2", password: "pw",
                role: "student", on: app)
            let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)

            // Not enrolled — should still redirect (silently ignored)
            try await app.asyncTest(
                .POST, "/courses/\(courseID.uuidString)/activate",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

        }
    }

    @Test func activateCourse_invalidCourseID_returns400() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "act_student3", password: "pw",
                role: "student", on: app)
            let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/courses/not-a-uuid/activate",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .badRequest)
                })

        }
    }

    // MARK: - Admin enrollment-mode route

    @Test func adminSetEnrollmentMode_setsMode() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "ADM_MODE1", mode: .open)
            let courseID = try course.requireID()
            let cookie = try await loginUser(
                username: "adm_mode_admin", password: "pw",
                role: "admin", on: app)

            let (token, newCookie) = try await csrfFields(
                for: "/admin/courses/\(courseID.uuidString)", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/admin/courses/\(courseID.uuidString)/enrollment-mode",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    req.headers.contentType = .urlEncodedForm
                    req.body = .init(string: "enrollmentMode=auto&_csrf=\(token)")
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            let updated = try await APICourse.find(courseID, on: app.db)
            #expect(updated?.enrollmentMode == .auto, "Enrollment mode should be .auto after update")

        }
    }

    @Test func adminSetEnrollmentMode_unknownValue_defaultsToOpen() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "ADM_MODE2", mode: .auto)
            let courseID = try course.requireID()
            let cookie = try await loginUser(
                username: "adm_mode_admin2", password: "pw",
                role: "admin", on: app)

            let (token, newCookie) = try await csrfFields(
                for: "/admin/courses/\(courseID.uuidString)", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/admin/courses/\(courseID.uuidString)/enrollment-mode",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    req.headers.contentType = .urlEncodedForm
                    req.body = .init(string: "enrollmentMode=bogus&_csrf=\(token)")
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            let updated = try await APICourse.find(courseID, on: app.db)
            #expect(updated?.enrollmentMode == .open, "Unknown value should default to .open")

        }
    }

    @Test func instructorSetEnrollmentMode_setsMode() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "INS_MODE1", mode: .open)
            let courseID = try course.requireID()
            let cookie = try await loginUser(
                username: "ins_mode_instructor", password: "pw",
                role: "instructor", on: app)

            let (token, newCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/courses/\(courseID.uuidString)/enrollment-mode",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    req.headers.contentType = .urlEncodedForm
                    req.body = .init(string: "enrollmentMode=closed&_csrf=\(token)")
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            let updated = try await APICourse.find(courseID, on: app.db)
            #expect(updated?.enrollmentMode == .closed)

        }
    }
}
