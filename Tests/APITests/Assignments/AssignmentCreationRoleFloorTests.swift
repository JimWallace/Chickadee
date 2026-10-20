// Tests/APITests/Assignments/AssignmentCreationRoleFloorTests.swift
//
// Creating an assignment is an `.instructor` action (docs/multi-course-roles.md,
// "assignment create/delete/open/close"). `ActiveCourseStaffMiddleware` admits a
// TA to `/instructor`, so each door that creates one states its own floor:
// quick publish (`POST /instructor`), save (`POST /instructor/new/save`) and the
// draft that starts a new assignment (`POST /instructor/new/draft`). A TA is
// refused and nothing is created; an instructor is not refused; an instructor of
// an archived course is refused.
//
// `InstructorParameterlessRouteFloorTests` found these three routes (#2710).

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class AssignmentCreationRoleFloorTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-create-floor")
    }

    private struct Actor {
        let cookie: String
        let csrf: String
    }

    /// `username`, enrolled in `courseID` at `role` (their only course, so it
    /// is their active one), signed in.
    private func actor(_ username: String, role: CourseRole, courseID: UUID) async throws -> Actor {
        let cookie = try await loginUser(username: username, password: "pw", role: "user", on: app)
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first())
        try await APICourseEnrollment(userID: try user.requireID(), courseID: courseID, role: role).save(on: app.db)
        let (csrf, sessionCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)
        return Actor(cookie: sessionCookie, csrf: csrf)
    }

    private func course(_ code: String, archived: Bool = false) async throws -> UUID {
        try await makeTestCourse(on: app, code: code, archived: archived, mode: .closed).requireID()
    }

    /// Quick publish of an existing setup in the course.
    private func publish(setupID: String, as actor: Actor) async throws -> HTTPStatus {
        var observed: HTTPStatus = .internalServerError
        try await app.asyncTest(
            .POST, "/instructor",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: actor.cookie)
                try req.content.encode(
                    ["_csrf": actor.csrf, "testSetupID": setupID, "title": "Floor Lab"], as: .urlEncodedForm)
            },
            afterResponse: { res in observed = res.status })
        return observed
    }

    /// A multipart post to one of the new-assignment form routes.
    private func multipart(_ path: String, as actor: Actor, fields: [(String, String)]) async throws -> HTTPStatus {
        let boundary = "Boundary-Create-Floor"
        var observed: HTTPStatus = .internalServerError
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: actor.cookie)
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                req.body = .init(
                    buffer: arMultipartBody(boundary: boundary, fields: [("_csrf", actor.csrf)] + fields))
            },
            afterResponse: { res in observed = res.status })
        return observed
    }

    private func newDraft(as actor: Actor) async throws -> HTTPStatus {
        try await multipart(
            "/instructor/new/draft", as: actor,
            fields: [("assignmentName", "Floor Draft"), ("draftAction", "create-assignment-notebook")])
    }

    private func save(as actor: Actor) async throws -> HTTPStatus {
        try await multipart("/instructor/new/save", as: actor, fields: [("assignmentName", "Floor Save")])
    }

    private func setupCount(_ courseID: UUID) async throws -> Int {
        try await APITestSetup.query(on: app.db).filter(\.$courseID == courseID).count()
    }

    private func assignmentCount(_ courseID: UUID) async throws -> Int {
        try await APIAssignment.query(on: app.db).filter(\.$courseID == courseID).count()
    }

    @Test func aTACannotCreateAnAssignment() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("CFTA")
            try await makeTestSetup(on: app, id: "cf_ta_setup", courseID: courseID)
            let ta = try await actor("cf_ta", role: .ta, courseID: courseID)

            #expect(try await publish(setupID: "cf_ta_setup", as: ta) == .forbidden)
            #expect(try await newDraft(as: ta) == .forbidden)
            #expect(try await save(as: ta) == .forbidden)
            #expect(try await assignmentCount(courseID) == 0)
            #expect(try await setupCount(courseID) == 1)
        }
    }

    private func newAssignmentPage(as actor: Actor) async throws -> HTTPStatus {
        var observed: HTTPStatus = .internalServerError
        try await app.asyncTest(
            .GET, "/instructor/new",
            beforeRequest: { req in req.headers.add(name: .cookie, value: actor.cookie) },
            afterResponse: { res in observed = res.status })
        return observed
    }

    @Test func onlyAnInstructorSeesTheNewAssignmentForm() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("CFPAGE")
            let ta = try await actor("cf_page_ta", role: .ta, courseID: courseID)
            let instructor = try await actor("cf_page_instructor", role: .instructor, courseID: courseID)

            #expect(try await newAssignmentPage(as: ta) == .forbidden)
            #expect(try await newAssignmentPage(as: instructor) == .ok)
        }
    }

    /// The staff dashboard offers the new-assignment form only to a viewer
    /// who may create one. A TA keeps the material items of the "+ Add" menu.
    @Test func anEmptyDashboardTellsATAWhoCreatesAssignments() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("CFEMPTY")
            let ta = try await actor("cf_empty_ta", role: .ta, courseID: courseID)

            let taPage = try await getHTML("/instructor", cookie: ta.cookie, on: app)
            #expect(taPage.contains("No assignments yet. A course instructor creates them."))
            #expect(!taPage.contains("Create one to get started."))
        }
    }

    @Test func theDashboardOffersTheFormOnlyToAnInstructor() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("CFDASH")
            try await makeTestSetup(on: app, id: "cf_dash_setup", courseID: courseID)
            _ = try await makeTestAssignment(on: app, testSetupID: "cf_dash_setup", courseID: courseID)
            let ta = try await actor("cf_dash_ta", role: .ta, courseID: courseID)
            let instructor = try await actor("cf_dash_instructor", role: .instructor, courseID: courseID)

            let taPage = try await getHTML("/instructor", cookie: ta.cookie, on: app)
            let instructorPage = try await getHTML("/instructor", cookie: instructor.cookie, on: app)
            // The new-assignment form, bare or with `?sectionID=`; not `/new-term`.
            func offersTheForm(_ html: String) -> Bool {
                html.contains("href=\"/instructor/new\"") || html.contains("href=\"/instructor/new?")
            }
            #expect(!offersTheForm(taPage))
            #expect(taPage.contains("data-add-kind=\"slides\""))
            #expect(offersTheForm(instructorPage))
        }
    }

    @Test func anInstructorCanCreateAnAssignment() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("CFINS")
            try await makeTestSetup(on: app, id: "cf_ins_setup", courseID: courseID)
            let instructor = try await actor("cf_instructor", role: .instructor, courseID: courseID)

            #expect(try await publish(setupID: "cf_ins_setup", as: instructor) == .seeOther)
            #expect(try await assignmentCount(courseID) == 1)
            #expect(try await newDraft(as: instructor) == .seeOther)
            #expect(try await setupCount(courseID) == 2)
            // The save has no notebook, so it bounces back to the form.
            #expect(try await save(as: instructor) == .seeOther)
        }
    }

    @Test func anInstructorOfAnArchivedCourseCannotCreateAnAssignment() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("CFARC", archived: true)
            try await makeTestSetup(on: app, id: "cf_arc_setup", courseID: courseID)
            let instructor = try await actor("cf_arc_instructor", role: .instructor, courseID: courseID)

            #expect(try await publish(setupID: "cf_arc_setup", as: instructor) == .forbidden)
            #expect(try await newDraft(as: instructor) == .forbidden)
            #expect(try await save(as: instructor) == .forbidden)
            #expect(try await assignmentCount(courseID) == 0)
            #expect(try await setupCount(courseID) == 1)
        }
    }
}
