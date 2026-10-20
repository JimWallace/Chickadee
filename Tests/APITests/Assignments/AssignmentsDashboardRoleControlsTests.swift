// Tests/APITests/Assignments/AssignmentsDashboardRoleControlsTests.swift
//
// The assignments dashboard (`GET /instructor`) serves a TA and an instructor.
// It shows a control only to a viewer who meets the floor of the route that
// the control calls (`DashboardRoleFloor`), so a TA is not offered an action
// that the server refuses with 403 (#2743). A TA keeps the TA actions: retest,
// edit, the material items and the read-only status.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class AssignmentsDashboardRoleControlsTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-dashboard-role-controls")
    }

    /// A course with one section that holds a published assignment, plus an
    /// unpublished setup.
    private struct Course {
        let courseID: UUID
        let sectionID: String
        let assignmentID: String
        let unpublishedSetupID: String
    }

    private func makeCourse(_ code: String) async throws -> Course {
        let courseID = try await makeTestCourse(on: app, code: code, mode: .closed).requireID()
        let section = APICourseSection(
            name: "Labs", defaultGradingMode: "worker", sortOrder: 1, courseID: courseID)
        try await section.save(on: app.db)
        let setupID = "\(code.lowercased())_setup"
        try await makeTestSetup(on: app, id: setupID, courseID: courseID)
        let assignment = try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)
        assignment.sectionID = try section.requireID()
        try await assignment.save(on: app.db)
        let unpublishedSetupID = "\(code.lowercased())_unpublished"
        try await makeTestSetup(on: app, id: unpublishedSetupID, courseID: courseID)
        return Course(
            courseID: courseID, sectionID: try section.requireID().uuidString,
            assignmentID: assignment.publicID, unpublishedSetupID: unpublishedSetupID)
    }

    /// `username`, signed in with deployment role `deploymentRole` and
    /// enrolled in `courseID` at `role` (their only course, so it is their
    /// active one). Returns the session cookie.
    private func signIn(
        _ username: String, deploymentRole: String = "user", role: CourseRole, courseID: UUID
    ) async throws -> String {
        let cookie = try await loginUser(username: username, password: "pw", role: deploymentRole, on: app)
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first())
        try await APICourseEnrollment(userID: try user.requireID(), courseID: courseID, role: role).save(on: app.db)
        return cookie
    }

    /// The markup of each control whose route floor is `.instructor`.
    private func instructorOnlyControls(_ course: Course) -> [String: String] {
        [
            "+ Add Section": "action=\"/instructor/sections\"",
            "section edit toggle": "js-section-edit-toggle",
            "section rename": "action=\"/instructor/sections/\(course.sectionID)/rename\"",
            "section delete": "data-action=\"/instructor/sections/\(course.sectionID)/delete\"",
            "status select": "action=\"/instructor/\(course.assignmentID)/status\"",
            "move between sections": "data-assignment-moves=\"free\"",
            "duplicate": "action=\"/instructor/\(course.assignmentID)/clone\"",
            "delete assignment": "action=\"/instructor/\(course.assignmentID)/delete\"",
            "publish setup": "class=\"publish-form\"",
            "delete setup": "action=\"/instructor/setup/\(course.unpublishedSetupID)/delete\"",
        ]
    }

    @Test func aTADoesNotSeeTheInstructorOnlyControls() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse("DRCTA")
            let cookie = try await signIn("drc_ta", role: .ta, courseID: course.courseID)

            let html = try await getHTML("/instructor", cookie: cookie, on: app)
            for (name, marker) in instructorOnlyControls(course) {
                #expect(!html.contains(marker), "A TA sees the \(name) control")
            }
        }
    }

    @Test func aTAKeepsTheTAControls() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse("DRCKEEP")
            let cookie = try await signIn("drc_keep_ta", role: .ta, courseID: course.courseID)

            let html = try await getHTML("/instructor", cookie: cookie, on: app)
            #expect(html.contains("action=\"/instructor/\(course.assignmentID)/retest\""))
            #expect(html.contains("href=\"/instructor/\(course.assignmentID)/workbench\""))
            #expect(html.contains("data-add-kind=\"slides\""))
            #expect(html.contains("class=\"tier tier-open\""))
            #expect(html.contains("section-drag-handle"))
            #expect(html.contains("An instructor publishes it."))
            // section-items-dnd.js keeps a TA's assignment drag in its section.
            #expect(html.contains("data-assignment-moves=\"locked\""))
        }
    }

    @Test func anInstructorSeesEveryInstructorOnlyControl() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse("DRCINS")
            let cookie = try await signIn("drc_instructor", role: .instructor, courseID: course.courseID)

            let html = try await getHTML("/instructor", cookie: cookie, on: app)
            for (name, marker) in instructorOnlyControls(course) {
                #expect(html.contains(marker), "An instructor does not see the \(name) control")
            }
            #expect(!html.contains("An instructor publishes it."))
        }
    }

    @Test func anAdminSeesEveryInstructorOnlyControl() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse("DRCADM")
            let cookie = try await signIn(
                "drc_admin", deploymentRole: "admin", role: .ta, courseID: course.courseID)

            let html = try await getHTML("/instructor", cookie: cookie, on: app)
            for (name, marker) in instructorOnlyControls(course) {
                #expect(html.contains(marker), "An admin does not see the \(name) control")
            }
        }
    }

    /// The enrol-CSV form feeds an `.instructor` POST, so a TA cannot open it
    /// by URL.
    @Test func onlyAnInstructorOpensTheEnrolCSVForm() async throws {
        try await withApp(app) { _ in
            let course = try await makeCourse("DRCCSV")
            let taCookie = try await signIn("drc_csv_ta", role: .ta, courseID: course.courseID)
            let instructorCookie = try await signIn(
                "drc_csv_instructor", role: .instructor, courseID: course.courseID)

            let taResponse = try await getResponse("/instructor/enroll-csv", cookie: taCookie, on: app)
            #expect(taResponse.status == .forbidden)
            let instructorResponse = try await getResponse(
                "/instructor/enroll-csv", cookie: instructorCookie, on: app)
            #expect(instructorResponse.status == .ok)
        }
    }
}
