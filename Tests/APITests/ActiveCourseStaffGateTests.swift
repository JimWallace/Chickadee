// Tests/APITests/ActiveCourseStaffGateTests.swift
//
// Phase 4b (docs/multi-course-roles.md): the /instructor group is gated on
// *per-course* instructor authority (ActiveCourseStaffMiddleware) — it
// admits admins and a user who is an instructor in their active course, and
// turns away a student in the active course. This is the access-control flip
// that makes per-course instructors able to author while keeping a per-course
// student out of instructor tools.

import Core
import Fluent
import Testing
import VaporTesting

@testable import APIServer

@Suite struct ActiveCourseStaffGateTests {

    /// Drives GET /instructor as `username` (global role `globalRole`) enrolled
    /// in the single course with `courseRole`, returning the response status.
    private func instructorGateStatus(
        username: String, globalRole: String, courseRole: CourseRole,
        courseID: UUID, on app: Application
    ) async throws -> HTTPStatus {
        let cookie = try await loginUser(username: username, password: "pass", role: globalRole, on: app)
        let user = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == username).first())
        try await APICourseEnrollment(
            userID: try user.requireID(), courseID: courseID, role: courseRole
        ).save(on: app.db)

        var status: HTTPStatus = .ok
        try await app.asyncTest(
            .GET, "/instructor",
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in status = res.status })
        return status
    }

    @Test func admitsPerCourseInstructorAndTurnsAwayPerCourseStudent() async throws {
        try await withWebRoutesApp { app in
            let course = APICourse(code: "CS500", name: "Lab", enrollmentMode: .closed)
            try await course.save(on: app.db)
            let courseID = try course.requireID()

            // A global *student* enrolled as a per-course instructor is admitted.
            let instructorStatus = try await instructorGateStatus(
                username: "pcinstructor", globalRole: "student", courseRole: .instructor,
                courseID: courseID, on: app)
            #expect(instructorStatus == .ok, "a per-course instructor (global student) may use /instructor")

            // A global *student* enrolled as a student is turned away (redirect).
            let studentStatus = try await instructorGateStatus(
                username: "pcstudent", globalRole: "student", courseRole: .student,
                courseID: courseID, on: app)
            #expect(studentStatus != .ok, "a per-course student must not reach /instructor")
        }
    }

    @Test func admitsAdminEvenWithoutInstructorRole() async throws {
        try await withWebRoutesApp { app in
            let course = APICourse(code: "CS500", name: "Lab", enrollmentMode: .closed)
            try await course.save(on: app.db)
            // Admin enrolled with a *student* per-course role still gets in.
            let status = try await instructorGateStatus(
                username: "adm", globalRole: "admin", courseRole: .student,
                courseID: try course.requireID(), on: app)
            #expect(status == .ok, "admin bypasses the per-course instructor gate")
        }
    }
}
