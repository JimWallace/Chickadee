// Tests/APITests/Courses/ActiveCourseWriteTests.swift
//
// The write preamble of an instructor route on the active course (#2720):
// `Request.activeCourseForWrite` and `requireActiveCourseForWrite`, and the
// course that `evaluateCourseWrite` returns. A test-only route calls the
// helper, so these tests pin the helper itself and not one handler.

import Core
import Fluent
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct ActiveCourseWriteTests {

    /// Registers `GET /test/active-write?floor=ta|instructor&require=1`. It
    /// answers the active course's code, or "none" when the optional helper
    /// gives nil.
    private func registerProbe(on app: Application) {
        app.get("test", "active-write") { req async throws -> String in
            let user = try req.auth.require(APIUser.self)
            let floor: CourseRole = req.query[String.self, at: "floor"] == "ta" ? .ta : .instructor
            if req.query[String.self, at: "require"] == "1" {
                return try await req.requireActiveCourseForWrite(user, atLeast: floor, action: "probing").code
            }
            return try await req.activeCourseForWrite(user, atLeast: floor)?.code ?? "none"
        }
    }

    private func probe(
        _ app: Application, cookie: String, query: String
    ) async throws -> (HTTPStatus, String) {
        var result: (HTTPStatus, String) = (.internalServerError, "")
        try await app.asyncTest(
            .GET, "/test/active-write?\(query)",
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in result = (res.status, res.body.string) })
        return result
    }

    @Test func instructorGetsTheActiveCourse() async throws {
        try await withAssignmentRoutesApp { app in
            registerProbe(on: app)
            let cookie = try await arLoginAsInstructor(on: app)
            let (status, body) = try await probe(app, cookie: cookie, query: "floor=instructor")
            #expect(status == .ok)
            #expect(body == "TEST101")
            let (requiredStatus, requiredBody) = try await probe(
                app, cookie: cookie, query: "floor=instructor&require=1")
            #expect(requiredStatus == .ok)
            #expect(requiredBody == "TEST101")
        }
    }

    @Test func taPassesTheTAFloorOnly() async throws {
        try await withAssignmentRoutesApp { app in
            registerProbe(on: app)
            let cookie = try await loginAsCourseTA("testta", on: app)
            let (taStatus, taBody) = try await probe(app, cookie: cookie, query: "floor=ta")
            #expect(taStatus == .ok)
            #expect(taBody == "TEST101")
            let (instructorStatus, _) = try await probe(app, cookie: cookie, query: "floor=instructor")
            #expect(instructorStatus == .forbidden)
            let (requiredStatus, _) = try await probe(
                app, cookie: cookie, query: "floor=instructor&require=1")
            #expect(requiredStatus == .forbidden)
        }
    }

    @Test func studentIsRefusedAtTheTAFloor() async throws {
        try await withAssignmentRoutesApp { app in
            registerProbe(on: app)
            _ = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsStudent(on: app)
            let (status, _) = try await probe(app, cookie: cookie, query: "floor=ta")
            #expect(status == .forbidden)
        }
    }

    @Test func noActiveCourseIsNilOrABadRequest() async throws {
        try await withAssignmentRoutesApp { app in
            registerProbe(on: app)
            // No course exists, so the viewer has no active course.
            let cookie = try await arLoginAsStudent(on: app)
            let (status, body) = try await probe(app, cookie: cookie, query: "floor=ta")
            #expect(status == .ok)
            #expect(body == "none")
            let (requiredStatus, requiredBody) = try await probe(app, cookie: cookie, query: "floor=ta&require=1")
            #expect(requiredStatus == .badRequest)
            #expect(requiredBody.contains("probing"))
        }
    }

    // MARK: - evaluateCourseWrite returns the course it loads

    @Test func evaluateCourseWriteReturnsTheLoadedCourse() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS136")
            let courseID = try course.requireID()
            let instructor = try await makeTestUser(on: app, username: "prof", role: "instructor")
            try await makeTestEnrollment(on: app, userID: instructor.requireID(), courseID: courseID)

            let verdict = try await evaluateCourseWrite(
                user: instructor, courseID: courseID, atLeast: .instructor, db: app.db)
            #expect(verdict.denial == nil)
            if case .allowed(let loaded) = verdict {
                #expect(loaded?.id == courseID)
            }

            let returned = try await requireCourseWriteAccess(
                caller: instructor, courseID: courseID, atLeast: .ta, db: app.db)
            #expect(returned?.code == "CS136")
        }
    }

    @Test func evaluateCourseWriteNamesEachDenial() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS136")
            let courseID = try course.requireID()
            let archived = try await makeTestCourse(on: app, code: "CS001", archived: true)
            let archivedID = try archived.requireID()
            let student = try await makeTestUser(on: app, username: "pupil")
            try await makeTestEnrollment(on: app, userID: student.requireID(), courseID: courseID)
            let instructor = try await makeTestUser(on: app, username: "prof", role: "instructor")
            try await makeTestEnrollment(on: app, userID: instructor.requireID(), courseID: archivedID)
            let outsider = try await makeTestUser(on: app, username: "outsider")

            #expect(
                try await evaluateCourseWrite(user: outsider, courseID: courseID, atLeast: .ta, db: app.db)
                    .denial == .notEnrolled)
            #expect(
                try await evaluateCourseWrite(user: student, courseID: courseID, atLeast: .ta, db: app.db)
                    .denial == .roleTooLow(held: .student, required: .ta))
            #expect(
                try await evaluateCourseWrite(
                    user: instructor, courseID: archivedID, atLeast: .instructor, db: app.db
                ).denial == .archived)
        }
    }

    @Test func adminBypassLoadsTheCourseAndAllowsAMissingOne() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS136")
            let admin = try await makeTestUser(on: app, username: "boss", role: "admin")

            let loaded = try await requireCourseWriteAccess(
                caller: admin, courseID: course.requireID(), atLeast: .instructor, db: app.db)
            #expect(loaded?.code == "CS136")

            // An admin bypasses the policy, so a missing course is not a denial.
            let missing = try await evaluateCourseWrite(
                user: admin, courseID: UUID(), atLeast: .instructor, db: app.db)
            #expect(missing.denial == nil)
            let none = try await requireCourseWriteAccess(
                caller: admin, courseID: UUID(), atLeast: .instructor, db: app.db)
            #expect(none == nil)
        }
    }
}
