// Tests/APITests/AssignmentEnrollmentTests.swift
//
// Integration tests for AssignmentRoutes+Enrollment:
//   POST /courses/:courseID/enrollment-mode  — set enrollment mode
//   GET  /instructor/enroll-csv              — bulk-enrol upload form
//   POST /courses/:courseID/enroll-csv       — bulk-enrol from CSV upload

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class AssignmentEnrollmentTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-enroll")
    }

    // MARK: - Helpers

    private func makeCourse(code: String, mode: CourseEnrollmentMode = .closed) async throws -> APICourse {
        try await makeTestCourse(on: app, code: code, name: "Test \(code)", mode: mode)
    }

    private func makeStudent(username: String) async throws -> APIUser {
        try await makeTestStudent(on: app, username: username)
    }

    private func enroll(user: APIUser, in course: APICourse) async throws {
        // Seed the per-course role from the global role so a global-instructor
        // caller becomes a per-course instructor (Phase 5: authority is per-course).
        let role: CourseRole = user.isInstructor ? .instructor : .student
        let enrollment = APICourseEnrollment(
            userID: try user.requireID(), courseID: try course.requireID(), role: role)
        try await enrollment.save(on: app.db)
    }

    /// Logs in a global instructor and enrols them as a per-course instructor in
    /// `course`, returning the session cookie. Phase 5 gates `/instructor` on the
    /// per-course role, so an instructor managing a course must be enrolled in it.
    private func loginInstructor(_ username: String, in course: APICourse) async throws -> String {
        let cookie = try await loginUser(username: username, password: "pw", role: "instructor", on: app)
        let user = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == username).first())
        try await APICourseEnrollment(
            userID: try user.requireID(), courseID: try course.requireID(), role: .instructor
        ).save(on: app.db)
        return cookie
    }

    // MARK: - POST /courses/:courseID/enrollment-mode

    @Test func setEnrollmentMode_instructorCanSetToOpen() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "OE_TOGGLE1", mode: .closed)
            let cookie = try await loginInstructor("oe_instructor1", in: course)
            let courseID = try course.requireID().uuidString
            let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/courses/\(courseID)/enrollment-mode",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    try req.content.encode(["enrollmentMode": "open", "_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            let updated = try await APICourse.find(course.id, on: app.db)
            #expect(updated?.enrollmentMode == .open)

        }
    }

    @Test func setEnrollmentMode_instructorCanSetToClosed() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "OE_TOGGLE2", mode: .open)
            let cookie = try await loginInstructor("oe_instructor2", in: course)
            let courseID = try course.requireID().uuidString
            let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/courses/\(courseID)/enrollment-mode",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    try req.content.encode(["enrollmentMode": "closed", "_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            let updated = try await APICourse.find(course.id, on: app.db)
            #expect(updated?.enrollmentMode == .closed)

        }
    }

    @Test func setEnrollmentMode_studentForbidden() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "OE_TOGGLE3")
            let cookie = try await loginUser(
                username: "oe_student1", password: "pw",
                role: "student", on: app)
            let courseID = try course.requireID().uuidString
            let (token, newCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/courses/\(courseID)/enrollment-mode",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    try req.content.encode(["enrollmentMode": "open", "_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })

        }
    }

    @Test func setEnrollmentMode_notFound() async throws {
        try await withApp(app) { _ in
            // Enrol the instructor in a real course so they clear the per-course
            // section gate; the POST then targets a bogus course → 404.
            let realCourse = try await makeCourse(code: "OE_NOTFOUND")
            let cookie = try await loginInstructor("oe_instructor3", in: realCourse)
            let bogusID = UUID().uuidString
            let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/courses/\(bogusID)/enrollment-mode",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    try req.content.encode(["enrollmentMode": "open", "_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })

        }
    }

    // MARK: - POST /courses/:courseID/enroll-csv

    @Test func enrollCSVFormShowsDedicatedUploadPage() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "CSV_FORM1")
            let cookie = try await loginUser(
                username: "csv_instructor_form", password: "pw",
                role: "instructor", on: app)
            let instructorQueryResult = try await APIUser.query(on: app.db)
                .filter(\.$username == "csv_instructor_form")
                .first()
            let instructor = try #require(instructorQueryResult)
            try await enroll(user: instructor, in: course)
            let courseID = try course.requireID().uuidString

            try await app.asyncTest(
                .GET, "/instructor/enroll-csv",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("Enrol from CSV"))
                    #expect(html.contains("/courses/\(courseID)/enroll-csv"))
                    #expect(html.contains("type=\"file\""))
                    #expect(html.contains("Cancel"))
                })

        }
    }

    @Test func bulkEnrollCSV_enrollsMatchedUsers() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "CSV_ENROLL1")
            _ = try await makeStudent(username: "csv_alice")
            _ = try await makeStudent(username: "csv_bob")
            let cookie = try await loginInstructor("csv_instructor1", in: course)
            let courseID = try course.requireID().uuidString
            let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)

            let csvData = "csv_alice\ncsv_bob\ncsv_notexist\n"

            try await app.asyncTest(
                .POST, "/courses/\(courseID)/enroll-csv",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    var body = ByteBufferAllocator().buffer(capacity: 256)
                    let boundary = "----TestBoundary"
                    let csvBytes = Array(csvData.utf8)
                    let part =
                        "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"users.csv\"\r\nContent-Type: text/csv\r\n\r\n\(csvData)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\n\(token)\r\n--\(boundary)--\r\n"
                    _ = csvBytes  // suppress unused warning
                    body.writeString(part)
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart", subType: "form-data",
                        parameters: ["boundary": boundary])
                    req.body = .init(buffer: body)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    // The result page shows enrolled count and notFound usernames
                    #expect(
                        html.contains("csv_notexist") || html.contains("2") || html.contains("enrolled"),
                        "Result page should report enrollment results")
                })

            let enrollments = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$course.$id == course.requireID())
                .filter(\.$roleRaw == CourseRole.student.rawValue)  // exclude the instructor fixture
                .all()
            #expect(enrollments.count == 2, "Both existing users should be enrolled")

        }
    }

    @Test func bulkEnrollCSV_skipsAlreadyEnrolled() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "CSV_ENROLL2")
            let student = try await makeStudent(username: "csv_charlie")
            // Pre-enroll charlie
            let enrollment = APICourseEnrollment(userID: try student.requireID(), courseID: try course.requireID())
            try await enrollment.save(on: app.db)

            let cookie = try await loginInstructor("csv_instructor2", in: course)
            let courseID = try course.requireID().uuidString
            let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)

            let csvData = "csv_charlie\n"
            let boundary = "----TestBoundary2"
            let part =
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"users.csv\"\r\nContent-Type: text/csv\r\n\r\n\(csvData)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\n\(token)\r\n--\(boundary)--\r\n"

            try await app.asyncTest(
                .POST, "/courses/\(courseID)/enroll-csv",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    var body = ByteBufferAllocator().buffer(capacity: 256)
                    body.writeString(part)
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart", subType: "form-data",
                        parameters: ["boundary": boundary])
                    req.body = .init(buffer: body)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                })

            let enrollments = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$course.$id == course.requireID())
                .filter(\.$roleRaw == CourseRole.student.rawValue)  // exclude the instructor fixture
                .all()
            #expect(enrollments.count == 1, "Should still be exactly one enrollment (no duplicate)")

        }
    }

    @Test func bulkEnroll_enrollsTypedUsernamesWithoutFile() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "CSV_TYPED1")
            _ = try await makeStudent(username: "typed_alice")
            _ = try await makeStudent(username: "typed_bob")
            let cookie = try await loginInstructor("typed_instructor1", in: course)
            let courseID = try course.requireID().uuidString
            let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)

            // No `file` part at all — only the typed `usernames` textarea.
            let typed = "typed_alice, typed_bob"
            let boundary = "----TypedBoundary1"
            let part =
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"usernames\"\r\n\r\n\(typed)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\n\(token)\r\n--\(boundary)--\r\n"

            try await app.asyncTest(
                .POST, "/courses/\(courseID)/enroll-csv",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    var body = ByteBufferAllocator().buffer(capacity: 256)
                    body.writeString(part)
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart", subType: "form-data",
                        parameters: ["boundary": boundary])
                    req.body = .init(buffer: body)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                })

            let enrollments = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$course.$id == course.requireID())
                .filter(\.$roleRaw == CourseRole.student.rawValue)
                .all()
            #expect(enrollments.count == 2, "Both typed users should be enrolled")
        }
    }

    @Test func bulkEnroll_rendersErrorWhenNothingSupplied() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "CSV_EMPTY1")
            let cookie = try await loginInstructor("empty_instructor1", in: course)
            let courseID = try course.requireID().uuidString
            let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)

            // Empty textarea, no file.
            let boundary = "----EmptyBoundary1"
            let part =
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"usernames\"\r\n\r\n   \r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\n\(token)\r\n--\(boundary)--\r\n"

            try await app.asyncTest(
                .POST, "/courses/\(courseID)/enroll-csv",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    var body = ByteBufferAllocator().buffer(capacity: 256)
                    body.writeString(part)
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart", subType: "form-data",
                        parameters: ["boundary": boundary])
                    req.body = .init(buffer: body)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("type at least one user ID"))
                })

            let enrollments = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$course.$id == course.requireID())
                .filter(\.$roleRaw == CourseRole.student.rawValue)
                .all()
            #expect(enrollments.isEmpty, "Nothing supplied should enroll no one")
        }
    }

    // MARK: - Pre-enrollment (no APIUser yet)

    @Test func bulkEnrollCSV_recordsPreEnrollmentForUnknownUsernames() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "CSV_PRE1")
            // alice exists; carol does not
            _ = try await makeStudent(username: "csv_pre_alice")
            let cookie = try await loginInstructor("csv_pre_instructor1", in: course)
            let courseID = try course.requireID().uuidString
            let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)

            let csvData = "csv_pre_alice\ncsv_pre_carol\n"
            let boundary = "----TestBoundaryPre1"
            let part =
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"u.csv\"\r\nContent-Type: text/csv\r\n\r\n\(csvData)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\n\(token)\r\n--\(boundary)--\r\n"

            try await app.asyncTest(
                .POST, "/courses/\(courseID)/enroll-csv",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    var body = ByteBufferAllocator().buffer(capacity: 256)
                    body.writeString(part)
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart", subType: "form-data",
                        parameters: ["boundary": boundary])
                    req.body = .init(buffer: body)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                })

            // alice was enrolled directly.
            let enrollments = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$course.$id == course.requireID())
                .filter(\.$roleRaw == CourseRole.student.rawValue)  // exclude the instructor fixture
                .all()
            #expect(enrollments.count == 1)

            // carol got recorded as a pre-enrollment.
            let preEnrollments = try await APIPreEnrollment.query(on: app.db)
                .filter(\.$course.$id == course.requireID())
                .all()
            #expect(preEnrollments.count == 1)
            #expect(preEnrollments.first?.username == "csv_pre_carol")

        }
    }

    @Test func resolvePendingPreEnrollments_promotesPendingToActiveOnLogin() async throws {
        try await withApp(app) { _ in
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
            #expect(remainingPending == 0)

            let enrollments = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$course.$id == courseID)
                .filter(\.$userID == user.requireID())
                .count()
            #expect(enrollments == 1)

        }
    }

    @Test func resolvePendingPreEnrollments_isIdempotent() async throws {
        try await withApp(app) { _ in
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
            #expect(enrollments == 1)

        }
    }

    @Test func bulkEnrollCSV_isIdempotentOnReupload() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "CSV_PRE4")
            let cookie = try await loginInstructor("csv_pre_instructor4", in: course)
            let courseID = try course.requireID().uuidString
            let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)

            let csvData = "csv_pre_dup\n"
            let boundary = "----TestBoundaryPre4"

            func upload(cookie: String, token: String) async throws {
                let part =
                    "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"u.csv\"\r\nContent-Type: text/csv\r\n\r\n\(csvData)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\n\(token)\r\n--\(boundary)--\r\n"
                try await app.asyncTest(
                    .POST, "/courses/\(courseID)/enroll-csv",
                    beforeRequest: { req in
                        req.headers.add(name: .cookie, value: cookie)
                        var body = ByteBufferAllocator().buffer(capacity: 256)
                        body.writeString(part)
                        req.headers.contentType = HTTPMediaType(
                            type: "multipart", subType: "form-data",
                            parameters: ["boundary": boundary])
                        req.body = .init(buffer: body)
                    },
                    afterResponse: { res in
                        #expect(res.status == .ok)
                    })
            }

            try await upload(cookie: newCookie, token: token)
            try await upload(cookie: newCookie, token: token)

            let preEnrollments = try await APIPreEnrollment.query(on: app.db)
                .filter(\.$course.$id == course.requireID())
                .all()
            #expect(preEnrollments.count == 1, "Re-uploading should not create a duplicate pre_enrollment")

        }
    }

    @Test func preUnenroll_removesPendingRow() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "CSV_PRE5")
            let courseID = try course.requireID()

            // Pre-create a pending row.
            let pending = APIPreEnrollment(courseID: courseID, username: "csv_pre_cancel")
            try await pending.save(on: app.db)
            let preID = try pending.requireID().uuidString

            let cookie = try await loginInstructor("csv_pre_instructor5", in: course)
            let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/courses/\(courseID.uuidString)/pre-unenroll/\(preID)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            let pendingID = try pending.requireID()
            let remaining = try await APIPreEnrollment.query(on: app.db)
                .filter(\.$id == pendingID)
                .count()
            #expect(remaining == 0)

        }
    }

    @Test func preUnenroll_studentForbidden() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "CSV_PRE6")
            let courseID = try course.requireID()

            let pending = APIPreEnrollment(courseID: courseID, username: "csv_pre_studentforbidden")
            try await pending.save(on: app.db)
            let preID = try pending.requireID().uuidString

            let cookie = try await loginUser(
                username: "csv_pre_student6", password: "pw",
                role: "student", on: app)
            let (token, newCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/courses/\(courseID.uuidString)/pre-unenroll/\(preID)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })

            // Pending row still exists.
            let pendingID = try pending.requireID()
            let remaining = try await APIPreEnrollment.query(on: app.db)
                .filter(\.$id == pendingID)
                .count()
            #expect(remaining == 1)

        }
    }

    @Test func registerPreEnrollment_materializesUserAndEnrolls() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "CSV_REG1")
            let courseID = try course.requireID()

            let pending = APIPreEnrollment(courseID: courseID, username: "csv_pre_register")
            try await pending.save(on: app.db)
            let preID = try pending.requireID().uuidString

            let cookie = try await loginInstructor("csv_reg_instructor1", in: course)
            let (token, newCookie) = try await csrfFields(for: "/enroll", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/courses/\(courseID.uuidString)/pre-enroll/\(preID)/register",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    try req.content.encode(
                        [
                            "_csrf": token,
                            "displayName": "Reggie Test",
                            "externalSubject": "duo-sub-123",
                            "studentID": "20260001",
                        ], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            // Pre-enrollment is gone.
            let remaining = try await APIPreEnrollment.query(on: app.db)
                .filter(\.$id == pending.requireID())
                .count()
            #expect(remaining == 0)

            // A real student user now exists, carrying the supplied SSO identity.
            let user = try #require(
                try await APIUser.query(on: app.db)
                    .filter(\.$username == "csv_pre_register").first())
            #expect(user.role == UserRole.student.rawValue)
            #expect(user.authProvider == "duo-oidc")
            #expect(user.externalSubject == "duo-sub-123")
            #expect(user.displayName == "Reggie Test")
            #expect(user.studentID == "20260001")

            // And they're enrolled in the course.
            let enrollment = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$course.$id == courseID)
                .filter(\.$userID == user.requireID())
                .count()
            #expect(enrollment == 1)
        }
    }

    @Test func registerPreEnrollment_studentForbidden() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "CSV_REG2")
            let courseID = try course.requireID()

            let pending = APIPreEnrollment(courseID: courseID, username: "csv_pre_regforbidden")
            try await pending.save(on: app.db)
            let preID = try pending.requireID().uuidString

            let cookie = try await loginUser(
                username: "csv_reg_student2", password: "pw", role: "student", on: app)
            let (token, newCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/courses/\(courseID.uuidString)/pre-enroll/\(preID)/register",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })

            // Pending row untouched.
            let remaining = try await APIPreEnrollment.query(on: app.db)
                .filter(\.$id == pending.requireID())
                .count()
            #expect(remaining == 1)
        }
    }

    @Test func bulkEnrollCSV_studentForbidden() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse(code: "CSV_ENROLL3")
            let cookie = try await loginUser(
                username: "csv_student1", password: "pw",
                role: "student", on: app)
            let courseID = try course.requireID().uuidString
            let (token, newCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)

            let boundary = "----TestBoundary3"
            let part =
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"u.csv\"\r\nContent-Type: text/csv\r\n\r\nalice\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"_csrf\"\r\n\r\n\(token)\r\n--\(boundary)--\r\n"

            try await app.asyncTest(
                .POST, "/courses/\(courseID)/enroll-csv",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    var body = ByteBufferAllocator().buffer(capacity: 256)
                    body.writeString(part)
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart", subType: "form-data",
                        parameters: ["boundary": boundary])
                    req.body = .init(buffer: body)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })

        }
    }
}
