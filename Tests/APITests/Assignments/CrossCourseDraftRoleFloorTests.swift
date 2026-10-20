// Tests/APITests/Assignments/CrossCourseDraftRoleFloorTests.swift
//
// The role floors in the draft's own course (#2742), for a caller who is an
// instructor of the active course. Reading a draft (the new-assignment form,
// the draft solution notebook) needs `.ta` there, as `loadDraftSetupForRead`
// does. Saving a draft needs `.instructor` there, as `loadDraftSetupForWrite`
// does, because the save rewrites the draft and moves it into the active
// course. `CrossCourseSetupReferenceTests` covers a caller with no role in the
// draft's course.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class CrossCourseDraftRoleFloorTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-cross-course-draft-floor")
    }

    private struct Actor {
        let cookie: String
        let csrf: String
    }

    /// An instructor of `activeCourseID` (signed in with it active) who holds
    /// `draftRole` in `draftCourseID`.
    private func actor(
        _ username: String, activeCourseID: UUID, draftRole: CourseRole, draftCourseID: UUID
    ) async throws -> Actor {
        let cookie = try await loginUser(username: username, password: "pw", role: "user", on: app)
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first())
        let userID = try user.requireID()
        try await APICourseEnrollment(userID: userID, courseID: activeCourseID, role: .instructor).save(on: app.db)
        let (csrf, sessionCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)
        // Enrolled after the active course is set, so it stays active.
        try await APICourseEnrollment(userID: userID, courseID: draftCourseID, role: draftRole).save(on: app.db)
        return Actor(cookie: sessionCookie, csrf: csrf)
    }

    private func course(_ code: String) async throws -> UUID {
        try await makeTestCourse(on: app, code: code, mode: .closed).requireID()
    }

    private static let notebook = """
        {"cells":[],"metadata":{},"nbformat":4,"nbformat_minor":5}
        """

    private func get(_ path: String, as actor: Actor) async throws -> HTTPStatus {
        var observed: HTTPStatus = .internalServerError
        try await app.asyncTest(
            .GET, path,
            beforeRequest: { req in req.headers.add(name: .cookie, value: actor.cookie) },
            afterResponse: { res in observed = res.status })
        return observed
    }

    private func save(draftID: String, as actor: Actor) async throws -> HTTPStatus {
        let boundary = "Boundary-Cross-Course-Floor"
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
                        fields: [("_csrf", actor.csrf), ("assignmentName", "Floor Save"), ("draftID", draftID)],
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

    /// A draft in a second course, with a solution notebook where the draft
    /// routes read it.
    private func draft(_ id: String, courseID: UUID) async throws {
        try await makeTestSetup(on: app, id: id, courseID: courseID)
        let dir = try ensureDraftNotebookDirectory(testSetupsDirectory: app.testSetupsDirectory, setupID: id)
        try Self.notebook.write(toFile: dir + "solution.ipynb", atomically: true, encoding: .utf8)
    }

    private static let solutionPath = "/instructor/new/draft/solution-notebook?draftID="

    @Test func aTAOfTheDraftsCourseCanReadTheDraftButNotSaveIt() async throws {
        try await withApp(app) { _ in
            let courseA = try await course("XCFLTAA")
            let courseB = try await course("XCFLTAB")
            try await draft("xc_fl_ta_draft", courseID: courseB)
            let caller = try await actor(
                "xc_fl_ta", activeCourseID: courseA, draftRole: .ta, draftCourseID: courseB)

            #expect(try await get("/instructor/new?draftID=xc_fl_ta_draft", as: caller) == .ok)
            #expect(try await get(Self.solutionPath + "xc_fl_ta_draft", as: caller) == .ok)
            #expect(try await save(draftID: "xc_fl_ta_draft", as: caller) == .forbidden)
            let setup = try #require(try await APITestSetup.find("xc_fl_ta_draft", on: app.db))
            #expect(setup.courseID == courseB)
        }
    }

    @Test func aStudentOfTheDraftsCourseCannotReadOrSaveTheDraft() async throws {
        try await withApp(app) { _ in
            let courseA = try await course("XCFLSTA")
            let courseB = try await course("XCFLSTB")
            try await draft("xc_fl_st_draft", courseID: courseB)
            let caller = try await actor(
                "xc_fl_st", activeCourseID: courseA, draftRole: .student, draftCourseID: courseB)

            #expect(try await get("/instructor/new?draftID=xc_fl_st_draft", as: caller) == .forbidden)
            #expect(try await get(Self.solutionPath + "xc_fl_st_draft", as: caller) == .forbidden)
            #expect(try await save(draftID: "xc_fl_st_draft", as: caller) == .forbidden)
            let setup = try #require(try await APITestSetup.find("xc_fl_st_draft", on: app.db))
            #expect(setup.courseID == courseB)
        }
    }
}
