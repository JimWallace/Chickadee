// Tests/APITests/AdminCourseRoleRouteTests.swift
//
// Route-level coverage for the admin per-course staff selector (#417 Slice B):
// POST /admin/courses/:courseID/role/:userID sets a roster member's per-course
// role from the admin course page, so an admin can assign a course's
// instructors without first making the course their active one. Kept in its
// own file (rather than the large AdminRoutesTests) and driving the shared
// Fixtures.swift builders.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class AdminCourseRoleRouteTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-admin-role")
    }

    @Test func adminSetEnrollmentRoleUpdatesPerCourseRole() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginUser(
                username: "admin_role_rt", password: "testpassword", role: "admin", on: app)
            let user = try await makeTestUser(on: app, username: "staff_member_rt", role: "student")
            let userID = try user.requireID()
            let course = try await makeTestCourse(on: app, code: "STAFFRT", name: "Staffed Course")
            let courseID = try course.requireID()
            try await makeTestEnrollment(on: app, userID: userID, courseID: courseID)  // defaults to student

            let (token, sessionCookie) = try await csrfFields(
                for: "/admin/courses/\(courseID.uuidString)", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/admin/courses/\(courseID.uuidString)/role/\(userID.uuidString)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        ["role": "instructor", "_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(
                        res.headers.first(name: .location) == "/admin/courses/\(courseID.uuidString)")
                })

            let enrollment = try #require(
                try await APICourseEnrollment.query(on: app.db)
                    .filter(\.$userID == userID).filter(\.$course.$id == courseID).first())
            #expect(enrollment.role == .instructor)
        }
    }
}
