// Tests/APITests/Admin/AdminUserDeleteCleanupTests.swift
//
// Admin user deletion: the foreign-key cleanup that
// POST /admin/users/:userID/delete leaves behind (#562), and where the
// delete control renders.
//
// Split out of AdminRoutesTests.swift; the helpers these suites share are in
// AdminRouteFixtures.swift.

import Core
import Fluent
import Foundation
import NIOFoundationCompat
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class AdminUserDeleteCleanupTests: AdminRouteFixtures {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-admin-userdelete")
    }

    // MARK: - POST /admin/users/:userID/delete — FK cleanup (#562)

    /// Deleting a user must CASCADE-delete the `class_achievements` rows
    /// that reference them.  The FK constraint added by
    /// `AddUserFKConstraints` covers it, and the admin handler enforces the
    /// same semantics in application code.
    @Test func deleteUserCascadesClassAchievements() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)
            let student = try await makeUser(username: "fk_cascade_student", role: "student")
            let studentID = try student.requireID()
            let course = try await makeCourse(code: "FKC101", name: "FK Cascade")
            let courseID = try course.requireID()
            let setup = try await makeSetup(id: "fk_cascade_setup", courseID: courseID)
            _ = setup
            let submission = try await makeSubmission(
                id: "fk_cascade_sub", setupID: "fk_cascade_setup", userID: studentID)

            let achievement = APIClassAchievement(
                testSetupID: "fk_cascade_setup",
                achievementID: "speed_champion",
                userID: studentID,
                submissionID: try submission.requireID(),
                metricValue: 42
            )
            try await achievement.save(on: app.db)
            let preDeleteCount = try await APIClassAchievement.query(on: app.db)
                .filter(\.$userID == studentID)
                .count()
            #expect(preDeleteCount == 1)

            let (boundCookie, token) = try await csrfCookieAndToken(cookie)
            try await app.asyncTest(
                .POST, "/admin/users/\(studentID.uuidString)/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                }
            )

            let reloadedUser = try await APIUser.find(studentID, on: app.db)
            #expect(reloadedUser == nil)
            let postDeleteCount = try await APIClassAchievement.query(on: app.db)
                .filter(\.$userID == studentID)
                .count()
            #expect(postDeleteCount == 0, "class_achievements rows referencing the deleted user must be removed")

        }
    }

    /// Deleting an instructor who has retested submissions must NULL out
    /// `submissions.retested_by_user_id` — the submission row stays
    /// (immutable grade history) but the retest attribution drops.
    @Test func deleteUserNullsRetestedByReferences() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)
            let student = try await makeUser(username: "fk_null_student", role: "student")
            let studentID = try student.requireID()
            let instructor = try await makeUser(username: "fk_null_instructor", role: "instructor")
            let instructorID = try instructor.requireID()
            let course = try await makeCourse(code: "FKN101", name: "FK Null")
            let courseID = try course.requireID()
            _ = try await makeSetup(id: "fk_null_setup", courseID: courseID)
            let submission = try await makeSubmission(
                id: "fk_null_sub", setupID: "fk_null_setup", userID: studentID)
            submission.retestedByUserID = instructorID
            try await submission.save(on: app.db)

            let (boundCookie, token) = try await csrfCookieAndToken(cookie)
            try await app.asyncTest(
                .POST, "/admin/users/\(instructorID.uuidString)/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                }
            )

            let reloadedInstructor = try await APIUser.find(instructorID, on: app.db)
            #expect(reloadedInstructor == nil)
            let reloaded = try await APISubmission.find("fk_null_sub", on: app.db)
            #expect(reloaded != nil, "Submission row must be preserved as immutable grade history")
            #expect(
                reloaded?.retestedByUserID == nil, "retested_by_user_id must clear when the referenced user is deleted")

        }
    }

    /// Deleting a user removes their enrollments through the declared
    /// `ON DELETE CASCADE` on `course_enrollments.user_id`, which both
    /// backends enforce. The handler no longer deletes them by hand (#2285).
    @Test func deleteUserRemovesEnrollmentsThroughTheCascade() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)
            let student = try await makeUser(username: "fk_enrollment_student", role: "student")
            let studentID = try student.requireID()
            let course = try await makeCourse(code: "FKE101", name: "FK Enrollment")
            try await makeEnrollment(userID: studentID, courseID: try course.requireID())

            let (boundCookie, token) = try await csrfCookieAndToken(cookie)
            try await app.asyncTest(
                .POST, "/admin/users/\(studentID.uuidString)/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                }
            )

            #expect(try await APIUser.find(studentID, on: app.db) == nil)
            let remaining = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$userID == studentID)
                .count()
            #expect(remaining == 0, "course_enrollments rows must go with the user")
        }
    }

    @Test func adminUserActionsRenderDeleteInUsersTableOnly() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)
            let managedUser = try await makeUser(username: "managed_for_actions", role: "student")
            let userID = try managedUser.requireID()

            try await app.asyncTest(
                .GET, "/admin/users",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = String(buffer: res.body)
                    #expect(body.contains("<th>Actions</th>"))
                    #expect(body.contains("<th>Courses</th>") == false)
                    #expect(body.contains("/admin/users/\(userID.uuidString)/delete"))
                    #expect(body.contains("aria-label=\"Delete user\""))
                })

            try await app.asyncTest(
                .GET, "/admin/users/\(userID.uuidString)",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = String(buffer: res.body)
                    #expect(body.contains(">Delete User<") == false)
                    #expect(body.contains("/admin/users/\(userID.uuidString)/delete") == false)
                })

        }
    }
}
