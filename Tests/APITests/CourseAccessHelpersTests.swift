// Tests for the shared course-visibility/access helpers in
// CourseAccessHelpers.swift — the single resolver behind the dashboard tab
// strip (`resolveActiveCourse`) and the MCP listing surface (`list_courses`,
// `resources/list`), and the single enrollment predicate behind the web guard
// and the MCP tools' `authorizeCourseAccess`. These pin the policy: enrollment
// rows only, archived courses hidden from visibility, no role bypass inside
// the helpers themselves.

import Fluent
import Testing
import Vapor

@testable import APIServer

@Suite struct CourseAccessHelpersTests {
    @Test func enrolledCoursesReturnsOnlyEnrollmentRowsSortedByCode() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let zz = try await makeTestCourse(on: app, code: "ZZ100", name: "Last")
            let aa = try await makeTestCourse(on: app, code: "AA100", name: "First")
            _ = try await makeTestCourse(on: app, code: "CS246", name: "Not enrolled")
            let user = try await makeTestUser(on: app, username: "prof", role: "instructor")
            try await makeTestEnrollment(on: app, userID: user.requireID(), courseID: zz.requireID())
            try await makeTestEnrollment(on: app, userID: user.requireID(), courseID: aa.requireID())

            let courses = try await enrolledCourses(for: user.requireID(), on: app.db)
            #expect(courses.map(\.code) == ["AA100", "ZZ100"])
        }
    }

    @Test func enrolledCoursesHidesArchived() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let live = try await makeTestCourse(on: app, code: "CS136", name: "Live")
            let old = try await makeTestCourse(on: app, code: "CS001", name: "Retired")
            old.isArchived = true
            try await old.save(on: app.db)
            let user = try await makeTestUser(on: app, username: "prof", role: "instructor")
            try await makeTestEnrollment(on: app, userID: user.requireID(), courseID: live.requireID())
            try await makeTestEnrollment(on: app, userID: user.requireID(), courseID: old.requireID())

            let courses = try await enrolledCourses(for: user.requireID(), on: app.db)
            #expect(courses.map(\.code) == ["CS136"])
        }
    }

    @Test func enrolledCoursesCarriesNoAdminBypass() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await makeTestCourse(on: app, code: "CS136", name: "Systems")
            let boss = try await makeTestUser(on: app, username: "boss", role: "admin")

            let courses = try await enrolledCourses(for: boss.requireID(), on: app.db)
            #expect(courses.isEmpty)
        }
    }

    @Test func userIsEnrolledTracksTheEnrollmentRow() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS136", name: "Systems")
            let user = try await makeTestUser(on: app, username: "prof", role: "instructor")

            #expect(
                try await userIsEnrolled(
                    userID: user.requireID(), inCourse: course.requireID(), db: app.db) == false)
            try await makeTestEnrollment(on: app, userID: user.requireID(), courseID: course.requireID())
            #expect(
                try await userIsEnrolled(
                    userID: user.requireID(), inCourse: course.requireID(), db: app.db) == true)
        }
    }

    // MARK: - Per-request role memo (#1382 item 3)

    @Test func cachedCourseRoleIsMemoizedPerRequest() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS136", name: "Systems")
            let user = try await makeTestUser(on: app, username: "ta_user")
            let enrollment = APICourseEnrollment(
                userID: try user.requireID(), courseID: try course.requireID(), role: .ta)
            try await enrollment.save(on: app.db)

            let req = Request(application: app, on: app.eventLoopGroup.any())
            #expect(try await req.cachedIsCourseStaff(user, inCourse: course.requireID()))

            // Downgrade the enrollment behind the request's back: the memoized
            // answer holds for the rest of THIS request (that is the memo
            // working — one enrollment read per request)...
            enrollment.role = .student
            try await enrollment.save(on: app.db)
            #expect(try await req.cachedIsCourseStaff(user, inCourse: course.requireID()))

            // ...while a fresh request resolves the new role.
            let fresh = Request(application: app, on: app.eventLoopGroup.any())
            #expect(try await fresh.cachedIsCourseStaff(user, inCourse: course.requireID()) == false)
        }
    }

    @Test func cachedEnrollmentGuardMatchesTheFreeFunction() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS136", name: "Systems")
            let courseID = try course.requireID()
            let outsider = try await makeTestUser(on: app, username: "outsider")
            let member = try await makeTestUser(on: app, username: "member")
            try await makeTestEnrollment(on: app, userID: member.requireID(), courseID: courseID)
            let admin = try await makeTestUser(on: app, username: "boss", role: "admin")

            let req = Request(application: app, on: app.eventLoopGroup.any())
            await #expect(throws: Abort.self) {
                try await req.cachedRequireCourseEnrollment(caller: outsider, courseID: courseID)
            }
            try await req.cachedRequireCourseEnrollment(caller: member, courseID: courseID)
            // A nil role is memoized too — the denial repeats without a fresh
            // read, and stays a denial.
            await #expect(throws: Abort.self) {
                try await req.cachedRequireCourseEnrollment(caller: outsider, courseID: courseID)
            }
            // Admins bypass, as in `requireCourseEnrollment`.
            try await req.cachedRequireCourseEnrollment(caller: admin, courseID: courseID)
        }
    }

    @Test func mcpCourseAccessDeniesUnenrolledAdmin() async throws {
        // The MCP path: an admin token is enrollment-scoped — denied before
        // enrolling, allowed after, revoked again on unenroll.
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS136", name: "Systems")
            let boss = try await makeTestUser(on: app, username: "boss", role: "admin")
            let context = ToolContext(
                request: Request(application: app, on: app.eventLoopGroup.any()),
                subject: "boss",
                grantedScopes: [.read, .write])

            await #expect(throws: MCPToolError.self) {
                try await context.authorizeCourseAccess(course.requireID(), tool: "test")
            }

            let enrollment = APICourseEnrollment(
                userID: try boss.requireID(), courseID: try course.requireID())
            try await enrollment.save(on: app.db)
            try await context.authorizeCourseAccess(course.requireID(), tool: "test")

            try await enrollment.delete(on: app.db)
            await #expect(throws: MCPToolError.self) {
                try await context.authorizeCourseAccess(course.requireID(), tool: "test")
            }
        }
    }
}
