// Tests/APITests/RoleSelectAndOrgUnitRenderTests.swift
//
// Two UI-pass changes that a render test can see:
//
//   * The course-role select is one partial (`_role-select.leaf`) fed by a
//     `RoleSelectCell`. The instructor roster (students and staff) and the
//     admin course page each used to carry their own copy of it.
//   * The LEARN page's org-unit field is a `.popup-anchor` dialog, not a field
//     inside a `role="menu"` panel (#2065).

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct RoleSelectAndOrgUnitRenderTests {

    private func enroll(
        _ username: String, role: CourseRole, on app: Application
    ) async throws -> (user: APIUser, courseID: UUID) {
        let user = try await arInsertStudent(username: username, displayName: username, on: app)
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        try await APICourseEnrollment(userID: try user.requireID(), courseID: courseID, role: role)
            .save(on: app.db)
        return (user, courseID)
    }

    /// The text of the role form for `userID`, from its opening tag to its end.
    private func roleForm(for userID: UUID, in html: String) throws -> Substring {
        let select = try #require(html.range(of: "id=\"role-\(userID.uuidString)\""))
        let formStart = try #require(
            html.range(of: "<form", options: .backwards, range: html.startIndex..<select.lowerBound))
        let formEnd = try #require(html.range(of: "</form>", range: select.upperBound..<html.endIndex))
        return html[formStart.lowerBound..<formEnd.upperBound]
    }

    @Test func theRosterRendersOneRoleSelectForStudentsAndStaff() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (pupil, courseID) = try await enroll("roleselect_pupil", role: .student, on: app)
            let (assistant, _) = try await enroll("roleselect_ta", role: .ta, on: app)

            let html = try await getHTML("/instructor/students", cookie: cookie, on: app)
            for (user, role) in [(pupil, "student"), (assistant, "ta")] {
                let id = try user.requireID()
                let form = try roleForm(for: id, in: html)
                #expect(form.contains("action=\"/courses/\(courseID.uuidString)/role/\(id.uuidString)\""))
                #expect(form.contains("Role for \(user.username)"))
                #expect(form.contains("data-state=\"\(role)\""))
                #expect(form.contains("<option value=\"\(role)\" selected>"))
                #expect(form.contains("name='_csrf'"))
            }
        }
    }

    @Test func theAdminCoursePageRendersTheSameRoleSelect() async throws {
        let app = try await makeTestApp(prefix: "chickadee-role-select")
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("role_select_admin", on: app)
            let course = try await makeTestCourse(on: app, code: "ROLE101")
            let courseID = try course.requireID()
            let user = try await makeTestUser(on: app, username: "role_select_ta")
            let userID = try user.requireID()
            try await APICourseEnrollment(userID: userID, courseID: courseID, role: .ta).save(on: app.db)

            let html = try await getHTML("/admin/courses/\(courseID.uuidString)", cookie: cookie, on: app)
            let form = try roleForm(for: userID, in: html)
            #expect(form.contains("action=\"/admin/courses/\(courseID.uuidString)/role/\(userID.uuidString)\""))
            #expect(form.contains("Role for role_select_ta"))
            #expect(form.contains("<option value=\"ta\" selected>"))
        }
    }

    @Test func theOrgUnitFieldIsAPopoverDialogNotAMenu() async throws {
        try await withAssignmentRoutesApp { app in
            // The service account can verify an org unit, so the card offers the change.
            let credentials = BrightSpaceAppCredentials(
                baseURL: "https://learn.test", appID: "a", appKey: "k", debounceSecs: 90)
            app.brightSpaceAppCredentials = credentials
            app.brightSpaceClient = BrightSpaceAPIClient(
                config: BrightSpaceSyncConfig(app: credentials, userID: "svc", userKey: "svc-key"))
            _ = try await app.testCourseID(enrollmentMode: .auto)
            let cookie = try await arLoginAsInstructor(on: app)

            let html = try await getHTML("/instructor/brightspace", cookie: cookie, on: app)
            let input = try #require(html.range(of: "id=\"bs-org-unit-input\""))
            let dialog = try #require(
                html.range(
                    of: "role=\"dialog\" aria-label=\"Change org unit\"", options: .backwards,
                    range: html.startIndex..<input.lowerBound))
            // No menu opens between the dialog and the field.
            #expect(!html[dialog.upperBound..<input.lowerBound].contains("role=\"menu\""))
            #expect(html.contains("Save org unit"))
            #expect(!html.contains("More actions for the LEARN connection"))
        }
    }
}
