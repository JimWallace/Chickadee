// Tests/APITests/Assignments/InstructorDashboardWriteOutcomeTests.swift
//
// What `InstructorDashboardRoutes.swift` (and the listing helpers in
// `InstructorDashboardRoutes+List.swift`) do once the caller is authorized:
// the /instructor redirect for an admin with no course, the variant summary
// on a listing row, the status and open refusals, the reorder refusals for
// unknown items and for two courses, the BrightSpace save's redirect, and the
// unpublished-setup delete. `RouteAuthorizationMatrixTests` checks the
// per-course role floors by status; the tests here also check what the
// database and the disk hold after a refusal.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class InstructorDashboardWriteOutcomeTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-dashboard-write-outcome")
    }

    private struct Actor {
        let cookie: String
        let csrf: String
    }

    private struct Reply {
        let status: HTTPStatus
        let location: String?
    }

    private func actor(_ username: String, role: CourseRole, courseID: UUID) async throws -> Actor {
        let cookie = try await loginUser(username: username, password: "pw", role: "student", on: app)
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first())
        try await APICourseEnrollment(userID: try user.requireID(), courseID: courseID, role: role).save(on: app.db)
        let (csrf, sessionCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)
        return Actor(cookie: sessionCookie, csrf: csrf)
    }

    private func admin(_ username: String) async throws -> Actor {
        let cookie = try await loginAsAdmin(username, on: app)
        let (csrf, sessionCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)
        return Actor(cookie: sessionCookie, csrf: csrf)
    }

    private func course(_ code: String) async throws -> UUID {
        try await makeTestCourse(on: app, code: code, mode: .closed).requireID()
    }

    private func postForm(_ path: String, as actor: Actor, fields: [String: String]) async throws -> Reply {
        let response = try await app.asyncSendRequest(.POST, path) { req in
            req.headers.add(name: .cookie, value: actor.cookie)
            var form = fields
            form["_csrf"] = actor.csrf
            try req.content.encode(form, as: .urlEncodedForm)
        }
        return Reply(status: response.status, location: response.headers.first(name: .location))
    }

    private func postJSON(_ path: String, as actor: Actor, json: String) async throws -> HTTPStatus {
        let response = try await app.asyncSendRequest(.POST, path) { req in
            req.headers.add(name: .cookie, value: actor.cookie)
            req.headers.add(name: "x-csrf-token", value: actor.csrf)
            req.headers.contentType = .json
            req.body = ByteBuffer(string: json)
        }
        return response.status
    }

    private func reload(_ assignment: APIAssignment) async throws -> APIAssignment {
        try #require(try await APIAssignment.find(assignment.requireID(), on: app.db))
    }

    // MARK: - GET /instructor

    @Test func anAdminEnrolledNowhereIsSentToEnrol() async throws {
        try await withApp(app) { app in
            _ = try await course("DWO1")
            let response = try await getResponse(
                "/instructor", cookie: try await loginAsAdmin("dwo_admin_enrol", on: app), on: app)
            #expect(response.status == .seeOther)
            #expect(response.headers.first(name: .location) == "/enroll")
        }
    }

    @Test func anAdminOnADeploymentWithNoCourseSeesTheDashboard() async throws {
        try await withApp(app) { app in
            let response = try await getResponse(
                "/instructor", cookie: try await loginAsAdmin("dwo_admin_empty", on: app), on: app)
            #expect(response.status == .ok)
        }
    }

    @Test func aListingRowSummarisesItsValidationVariants() async throws {
        try await withApp(app) { app in
            let courseID = try await course("DWO2")
            let instructor = try await actor("dwo_variants", role: .instructor, courseID: courseID)
            let tester = try await makeTestStudent(on: app, username: "dwo_tester").requireID()

            try await makeTestSetup(on: app, id: "dwo_failed", courseID: courseID)
            try await makeTestAssignment(on: app, testSetupID: "dwo_failed", courseID: courseID, title: "Failing")
            try await makeTestSubmission(
                on: app, id: "dwo_sub_v0", setupID: "dwo_failed", userID: tester,
                kind: APISubmission.Kind.validation)
            let failed = ValidationVariant(
                testSetupID: "dwo_failed", variantIndex: 0, seedHex: "00", submissionID: "dwo_sub_v0")
            failed.status = ValidationVariant.Status.failed
            try await failed.save(on: app.db)
            let passed = ValidationVariant(testSetupID: "dwo_failed", variantIndex: 1, seedHex: "01", submissionID: nil)
            passed.status = ValidationVariant.Status.passed
            try await passed.save(on: app.db)

            try await makeTestSetup(on: app, id: "dwo_running", courseID: courseID)
            try await makeTestAssignment(on: app, testSetupID: "dwo_running", courseID: courseID, title: "Running")
            for index in 0..<3 {
                let variant = ValidationVariant(
                    testSetupID: "dwo_running", variantIndex: index, seedHex: "0\(index)", submissionID: nil)
                if index == 0 { variant.status = ValidationVariant.Status.failed }
                try await variant.save(on: app.db)
            }

            let page = try await getHTML("/instructor", cookie: instructor.cookie, on: app)
            #expect(page.contains("1 of 2 variants failed"))
            #expect(page.contains(#"href="/submissions/dwo_sub_v0""#), "the row links the failed variant")
            #expect(page.contains("3 variants running"), "a pending variant reads as still running")
        }
    }

    // MARK: - POST /instructor/:assignmentID/status and /open

    @Test func anUnknownStatusIsRefusedAndChangesNothing() async throws {
        try await withApp(app) { app in
            let scenario = try await TestScenario.make(on: app, code: "DWO3", mode: .closed, setupID: "dwo_status")
            let instructor = try await actor("dwo_status_inst", role: .instructor, courseID: scenario.courseID)
            let before = try await reload(scenario.assignment).visibility
            let reply = try await postForm(
                "/instructor/\(scenario.assignment.publicID)/status", as: instructor, fields: ["status": "archived"])
            #expect(reply.status == .badRequest)
            #expect(try await reload(scenario.assignment).visibility == before)
        }
    }

    @Test func previewIsSavedAndTheRedirectGoesToTheDashboard() async throws {
        try await withApp(app) { app in
            let scenario = try await TestScenario.make(
                on: app, code: "DWO4", mode: .closed, setupID: "dwo_preview", isOpen: false)
            let instructor = try await actor("dwo_preview_inst", role: .instructor, courseID: scenario.courseID)
            let reply = try await postForm(
                "/instructor/\(scenario.assignment.publicID)/status", as: instructor, fields: ["status": "preview"])
            #expect(reply.status == .seeOther)
            #expect(reply.location == "/instructor")
            #expect(try await reload(scenario.assignment).visibility == .preview)
        }
    }

    @Test func openingAnAssignmentWhoseValidationFailedIsRefusedOnBothRoutes() async throws {
        try await withApp(app) { app in
            let scenario = try await TestScenario.make(
                on: app, code: "DWO5", mode: .closed, setupID: "dwo_unvalidated", isOpen: false)
            scenario.assignment.validationStatus = "failed"
            try await scenario.assignment.save(on: app.db)
            let instructor = try await actor("dwo_open_inst", role: .instructor, courseID: scenario.courseID)
            let publicID = scenario.assignment.publicID

            let viaStatus = try await postForm(
                "/instructor/\(publicID)/status", as: instructor, fields: ["status": "open"])
            #expect(viaStatus.status == .badRequest)
            let viaOpen = try await postForm("/instructor/\(publicID)/open", as: instructor, fields: [:])
            #expect(viaOpen.status == .badRequest)
            #expect(try await reload(scenario.assignment).visibility == .closed)
        }
    }

    // MARK: - POST /instructor/section-items/reorder

    @Test func aReorderOfItemsThatDoNotExistIsRefused() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("DWO6")
            let instructor = try await actor("dwo_reorder_unknown", role: .instructor, courseID: courseID)
            let status = try await postJSON(
                "/instructor/section-items/reorder", as: instructor,
                json: #"{"items":[{"type":"assignment","id":"zz9zz9"}]}"#)
            #expect(status == .badRequest)
        }
    }

    @Test func aReorderOfItemsOfTwoCoursesIsRefusedEvenForAnAdmin() async throws {
        try await withApp(app) { app in
            let first = try await TestScenario.make(on: app, code: "DWO7A", mode: .closed, setupID: "dwo_mix_a")
            let second = try await TestScenario.make(on: app, code: "DWO7B", mode: .closed, setupID: "dwo_mix_b")
            first.assignment.sortOrder = 5
            try await first.assignment.save(on: app.db)
            second.assignment.sortOrder = 7
            try await second.assignment.save(on: app.db)
            let admin = try await admin("dwo_reorder_admin")
            let json = """
                {"items":[{"type":"assignment","id":"\(second.assignment.publicID)"},\
                {"type":"assignment","id":"\(first.assignment.publicID)"}]}
                """
            let status = try await postJSON("/instructor/section-items/reorder", as: admin, json: json)
            #expect(status == .badRequest)
            #expect(try await reload(first.assignment).sortOrder == 5)
            #expect(try await reload(second.assignment).sortOrder == 7)
        }
    }

    @Test func anInstructorOfAnotherCourseCannotReorderThisOne() async throws {
        try await withApp(app) { app in
            let scenario = try await TestScenario.make(on: app, code: "DWO8A", mode: .closed, setupID: "dwo_cross")
            scenario.assignment.sortOrder = 4
            try await scenario.assignment.save(on: app.db)
            let otherID = try await course("DWO8B")
            let outsider = try await actor("dwo_reorder_outsider", role: .instructor, courseID: otherID)
            let status = try await postJSON(
                "/instructor/section-items/reorder", as: outsider,
                json: #"{"items":[{"type":"assignment","id":"\#(scenario.assignment.publicID)"}]}"#)
            #expect(status == .forbidden)
            #expect(try await reload(scenario.assignment).sortOrder == 4)
        }
    }

    // MARK: - POST /instructor/:assignmentID/brightspace

    @Test func aBrightSpaceSaveFromTheEditorGoesBackToTheEditor() async throws {
        try await withApp(app) { app in
            let scenario = try await TestScenario.make(on: app, code: "DWO9", mode: .closed, setupID: "dwo_bs")
            let instructor = try await actor("dwo_bs_inst", role: .instructor, courseID: scenario.courseID)
            let publicID = scenario.assignment.publicID
            let reply = try await postForm(
                "/instructor/\(publicID)/brightspace", as: instructor, fields: ["gradeObjectID": "  4242 "])
            #expect(reply.status == .seeOther)
            #expect(reply.location == "/instructor/\(publicID)/edit?notice=BrightSpace+grade+item+ID+saved")
            #expect(try await reload(scenario.assignment).brightspaceGradeObjectID == "4242")
        }
    }

    // MARK: - POST /instructor/setup/:setupID/delete

    @Test func anUnknownSetupIsNotFound() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("DWO10")
            let instructor = try await actor("dwo_setup_missing", role: .instructor, courseID: courseID)
            let reply = try await postForm("/instructor/setup/dwo_no_such_setup/delete", as: instructor, fields: [:])
            #expect(reply.status == .notFound)
        }
    }

    @Test func anUnpublishedSetupIsDeletedWithItsFiles() async throws {
        try await withApp(app) { app in
            let courseID = try await course("DWO11")
            let instructor = try await actor("dwo_setup_delete", role: .instructor, courseID: courseID)
            let setup = try await makeTestSetup(on: app, id: "dwo_orphan", courseID: courseID)
            let notebookPath = try #require(setup.notebookPath)
            #expect(FileManager.default.fileExists(atPath: setup.zipPath))
            #expect(FileManager.default.fileExists(atPath: notebookPath))

            let reply = try await postForm("/instructor/setup/dwo_orphan/delete", as: instructor, fields: [:])
            #expect(reply.status == .seeOther)
            #expect(reply.location == "/instructor")
            #expect(try await APITestSetup.find("dwo_orphan", on: app.db) == nil)
            #expect(!FileManager.default.fileExists(atPath: setup.zipPath))
            #expect(!FileManager.default.fileExists(atPath: notebookPath))
        }
    }

    @Test func aSetupWithNoNotebookIsDeletedToo() async throws {
        try await withApp(app) { app in
            let courseID = try await course("DWO12")
            let instructor = try await actor("dwo_setup_nonb", role: .instructor, courseID: courseID)
            let setup = try await makeTestSetup(on: app, id: "dwo_orphan_nonb", courseID: courseID, withNotebook: false)
            let reply = try await postForm("/instructor/setup/dwo_orphan_nonb/delete", as: instructor, fields: [:])
            #expect(reply.status == .seeOther)
            #expect(try await APITestSetup.find("dwo_orphan_nonb", on: app.db) == nil)
            #expect(!FileManager.default.fileExists(atPath: setup.zipPath))
        }
    }

    @Test func anotherCoursesInstructorOrThisCoursesTALeavesTheSetupAndItsFiles() async throws {
        try await withApp(app) { app in
            let courseID = try await course("DWO13A")
            let otherID = try await course("DWO13B")
            let setup = try await makeTestSetup(on: app, id: "dwo_kept", courseID: courseID)
            let outsider = try await actor("dwo_setup_outsider", role: .instructor, courseID: otherID)
            let ta = try await actor("dwo_setup_ta", role: .ta, courseID: courseID)

            let cross = try await postForm("/instructor/setup/dwo_kept/delete", as: outsider, fields: [:])
            #expect(cross.status == .forbidden)
            let byTA = try await postForm("/instructor/setup/dwo_kept/delete", as: ta, fields: [:])
            #expect(byTA.status == .forbidden)
            #expect(try await APITestSetup.find("dwo_kept", on: app.db) != nil)
            #expect(FileManager.default.fileExists(atPath: setup.zipPath))
        }
    }

    @Test func aSetupWithAPublishedAssignmentIsKept() async throws {
        try await withApp(app) { app in
            let scenario = try await TestScenario.make(on: app, code: "DWO14", mode: .closed, setupID: "dwo_published")
            let instructor = try await actor("dwo_setup_published", role: .instructor, courseID: scenario.courseID)
            let reply = try await postForm("/instructor/setup/dwo_published/delete", as: instructor, fields: [:])
            #expect(reply.status == .conflict)
            #expect(try await APITestSetup.find("dwo_published", on: app.db) != nil)
            #expect(FileManager.default.fileExists(atPath: scenario.setup.zipPath))
        }
    }
}
