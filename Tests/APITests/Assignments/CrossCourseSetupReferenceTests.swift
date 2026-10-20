// Tests/APITests/Assignments/CrossCourseSetupReferenceTests.swift
//
// A test setup belongs to one course. `ActiveCourseStaffMiddleware` proves only
// that the caller is staff in the *active* course, so a route that takes a setup
// ID in its body or query string must check that setup's own course (#2742).
//
// - Quick publish (`POST /instructor`) refuses a setup that is not in the
//   active course, because the new assignment would sit in one course and its
//   setup in another.
// - The new-assignment form (`GET /instructor/new?draftID=`), its solution
//   notebook (`GET /instructor/new/draft/solution-notebook?draftID=`) and its
//   save (`POST /instructor/new/save`) authorize the draft's own course, as the
//   other draft routes do with `loadDraftSetupForRead` / `loadDraftSetupForWrite`.
//   A save can still move a draft into the active course when the caller is an
//   instructor of both courses.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class CrossCourseSetupReferenceTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-cross-course-setup")
    }

    private struct Actor {
        let userID: UUID
        let cookie: String
        let csrf: String
    }

    /// `username`, enrolled in `courseID` at `role` (their only course, so it
    /// becomes their active one), signed in.
    private func actor(_ username: String, role: CourseRole, courseID: UUID) async throws -> Actor {
        let cookie = try await loginUser(username: username, password: "pw", role: "user", on: app)
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first())
        let userID = try user.requireID()
        try await APICourseEnrollment(userID: userID, courseID: courseID, role: role).save(on: app.db)
        let (csrf, sessionCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)
        return Actor(userID: userID, cookie: sessionCookie, csrf: csrf)
    }

    private func course(_ code: String) async throws -> UUID {
        try await makeTestCourse(on: app, code: code, mode: .closed).requireID()
    }

    private func publish(setupID: String, as actor: Actor) async throws -> HTTPStatus {
        var observed: HTTPStatus = .internalServerError
        try await app.asyncTest(
            .POST, "/instructor",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: actor.cookie)
                try req.content.encode(
                    ["_csrf": actor.csrf, "testSetupID": setupID, "title": "Cross Lab"], as: .urlEncodedForm)
            },
            afterResponse: { res in observed = res.status })
        return observed
    }

    private static let notebook = """
        {"cells":[],"metadata":{},"nbformat":4,"nbformat_minor":5}
        """

    /// A save of draft `draftID` with both notebooks attached, so the save
    /// reaches the point where it writes the draft.
    private func save(draftID: String, as actor: Actor) async throws -> HTTPStatus {
        let boundary = "Boundary-Cross-Course"
        var observed: HTTPStatus = .internalServerError
        try await app.asyncTest(
            .POST, "/instructor/new/save",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: actor.cookie)
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                req.body = .init(
                    buffer: arMultipartBody(
                        boundary: boundary,
                        fields: [("_csrf", actor.csrf), ("assignmentName", "Cross Save"), ("draftID", draftID)],
                        files: [
                            (
                                "assignmentNotebookFile", "assignment.ipynb", "application/json",
                                Data(Self.notebook.utf8)
                            ),
                            ("solutionNotebookFile", "solution.ipynb", "application/json", Data(Self.notebook.utf8)),
                        ]))
            },
            afterResponse: { res in observed = res.status })
        return observed
    }

    private func get(_ path: String, as actor: Actor) async throws -> HTTPStatus {
        var observed: HTTPStatus = .internalServerError
        try await app.asyncTest(
            .GET, path,
            beforeRequest: { req in req.headers.add(name: .cookie, value: actor.cookie) },
            afterResponse: { res in observed = res.status })
        return observed
    }

    /// Writes a solution notebook for draft `setupID` where the draft routes read it.
    private func writeDraftSolution(setupID: String) throws {
        let dir = try ensureDraftNotebookDirectory(
            testSetupsDirectory: app.testSetupsDirectory, setupID: setupID)
        try Self.notebook.write(toFile: dir + "solution.ipynb", atomically: true, encoding: .utf8)
    }

    private func assignmentCount(_ courseID: UUID) async throws -> Int {
        try await APIAssignment.query(on: app.db).filter(\.$courseID == courseID).count()
    }

    private func setupCourse(_ setupID: String) async throws -> UUID? {
        try await APITestSetup.find(setupID, on: app.db)?.courseID
    }

    // MARK: - Quick publish

    @Test func quickPublishRefusesASetupFromAnotherCourse() async throws {
        try await withApp(app) { _ in
            let courseA = try await course("XCPUBA")
            let courseB = try await course("XCPUBB")
            try await makeTestSetup(on: app, id: "xc_pub_b_setup", courseID: courseB)
            let instructor = try await actor("xc_pub_instructor", role: .instructor, courseID: courseA)

            #expect(try await publish(setupID: "xc_pub_b_setup", as: instructor) == .forbidden)
            #expect(try await assignmentCount(courseA) == 0)
            #expect(try await assignmentCount(courseB) == 0)
        }
    }

    @Test func quickPublishRefusesASetupFromAnotherCourseTheCallerAlsoInstructs() async throws {
        try await withApp(app) { _ in
            let courseA = try await course("XCPUB2A")
            let courseB = try await course("XCPUB2B")
            try await makeTestSetup(on: app, id: "xc_pub2_b_setup", courseID: courseB)
            let instructor = try await actor("xc_pub2_instructor", role: .instructor, courseID: courseA)
            // Enrolled after the active course is set, so course A stays active.
            try await APICourseEnrollment(userID: instructor.userID, courseID: courseB, role: .instructor)
                .save(on: app.db)

            #expect(try await publish(setupID: "xc_pub2_b_setup", as: instructor) == .forbidden)
            #expect(try await assignmentCount(courseA) == 0)
            #expect(try await assignmentCount(courseB) == 0)
        }
    }

    @Test func quickPublishAcceptsASetupFromTheActiveCourse() async throws {
        try await withApp(app) { _ in
            let courseA = try await course("XCPUB3A")
            try await makeTestSetup(on: app, id: "xc_pub3_a_setup", courseID: courseA)
            let instructor = try await actor("xc_pub3_instructor", role: .instructor, courseID: courseA)

            #expect(try await publish(setupID: "xc_pub3_a_setup", as: instructor) == .seeOther)
            #expect(try await assignmentCount(courseA) == 1)
        }
    }

    // MARK: - Save

    @Test func saveRefusesADraftFromAnotherCourse() async throws {
        try await withApp(app) { _ in
            let courseA = try await course("XCSAVEA")
            let courseB = try await course("XCSAVEB")
            try await makeTestSetup(on: app, id: "xc_save_b_draft", courseID: courseB)
            let instructor = try await actor("xc_save_instructor", role: .instructor, courseID: courseA)

            #expect(try await save(draftID: "xc_save_b_draft", as: instructor) == .forbidden)
            #expect(try await setupCourse("xc_save_b_draft") == courseB)
            #expect(try await assignmentCount(courseA) == 0)
        }
    }

    /// An instructor of both courses may still publish a draft from one into
    /// the other: the save path moves the draft into the active course
    /// (docs/datasets-course-library.md).
    @Test func saveMovesADraftForAnInstructorOfBothCourses() async throws {
        try await withApp(app) { _ in
            let courseA = try await course("XCSAVE2A")
            let courseB = try await course("XCSAVE2B")
            try await makeTestSetup(on: app, id: "xc_save2_b_draft", courseID: courseB)
            let instructor = try await actor("xc_save2_instructor", role: .instructor, courseID: courseA)
            try await APICourseEnrollment(userID: instructor.userID, courseID: courseB, role: .instructor)
                .save(on: app.db)

            #expect(try await save(draftID: "xc_save2_b_draft", as: instructor) == .seeOther)
            #expect(try await setupCourse("xc_save2_b_draft") == courseA)
            #expect(try await assignmentCount(courseA) == 1)
        }
    }

    // MARK: - The new-assignment form and its solution notebook

    @Test func theNewAssignmentFormRefusesADraftFromAnotherCourse() async throws {
        try await withApp(app) { _ in
            let courseA = try await course("XCFORMA")
            let courseB = try await course("XCFORMB")
            try await makeTestSetup(on: app, id: "xc_form_b_draft", courseID: courseB)
            try await makeTestSetup(on: app, id: "xc_form_a_draft", courseID: courseA)
            let instructor = try await actor("xc_form_instructor", role: .instructor, courseID: courseA)

            #expect(try await get("/instructor/new?draftID=xc_form_b_draft", as: instructor) == .forbidden)
            #expect(try await get("/instructor/new?draftID=xc_form_a_draft", as: instructor) == .ok)
        }
    }

    @Test func theDraftSolutionNotebookRefusesADraftFromAnotherCourse() async throws {
        try await withApp(app) { _ in
            let courseA = try await course("XCSOLA")
            let courseB = try await course("XCSOLB")
            try await makeTestSetup(on: app, id: "xc_sol_b_draft", courseID: courseB)
            try await makeTestSetup(on: app, id: "xc_sol_a_draft", courseID: courseA)
            try writeDraftSolution(setupID: "xc_sol_b_draft")
            try writeDraftSolution(setupID: "xc_sol_a_draft")
            let instructor = try await actor("xc_sol_instructor", role: .instructor, courseID: courseA)

            let path = "/instructor/new/draft/solution-notebook?draftID="
            #expect(try await get(path + "xc_sol_b_draft", as: instructor) == .forbidden)
            #expect(try await get(path + "xc_sol_a_draft", as: instructor) == .ok)
        }
    }
}
