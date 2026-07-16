// Tests/APITests/InstructorEditorReadAuthTests.swift
//
// #1103 — the instructor-editor READ endpoints must authorize against the
// resource's own course, exactly like the write endpoints do. Before the fix,
// `loadAssignmentAndSetup` / `loadDraftSetup(requireWrite: false)` performed
// no per-course check, so an active TA of course A could fetch course B's
// reference solution and secret tests by guessing its 6-char assignment
// public ID — the same cross-course hole #417 Slice G closed on the API side.
//
// The acting user here ("outsider") is staff (`.ta`) in their OWN course — so
// they pass the `/instructor` group's ActiveCourseStaffMiddleware gate —
// but hold no enrollment in the course that owns the target assignment/draft.
// Every editor read must 403. An enrolled TA of the owning course ("insider")
// keeps access.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class InstructorEditorReadAuthTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-editor-read-auth")
    }

    private struct Fixture {
        let assignmentID: String
        let draftID: String
        let outsiderCookie: String
        let insiderCookie: String
    }

    /// Two `.closed` courses (no auto-enroll): the target assignment + a
    /// draft setup live in OWNED; `outsider_ta` is a TA only in OTHER, and
    /// `insider_ta` is a TA in OWNED.
    private func fixture() async throws -> Fixture {
        let owned = try await makeTestCourse(on: app, code: "OWNED", name: "Owning Course", mode: .closed)
        let other = try await makeTestCourse(on: app, code: "OTHER", name: "Other Course", mode: .closed)
        let ownedID = try owned.requireID()

        try await makeTestSetup(on: app, id: "read_auth_setup", courseID: ownedID)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: "read_auth_setup", courseID: ownedID, title: "Secret Lab")
        // A draft is a setup row with no assignment parent.
        try await makeTestSetup(on: app, id: "read_auth_draft", courseID: ownedID)

        let outsiderCookie = try await loginUser(
            username: "outsider_ta", password: "pw", role: "user", on: app)
        let outsider = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "outsider_ta").first())
        try await APICourseEnrollment(
            userID: try outsider.requireID(), courseID: try other.requireID(), role: .ta
        ).save(on: app.db)

        let insiderCookie = try await loginUser(
            username: "insider_ta", password: "pw", role: "user", on: app)
        let insider = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "insider_ta").first())
        try await APICourseEnrollment(
            userID: try insider.requireID(), courseID: ownedID, role: .ta
        ).save(on: app.db)

        return Fixture(
            assignmentID: assignment.publicID,
            draftID: "read_auth_draft",
            outsiderCookie: outsiderCookie,
            insiderCookie: insiderCookie)
    }

    private func expectStatus(
        _ path: String, cookie: String, _ expected: HTTPStatus,
        _ note: Comment
    ) async throws {
        try await app.asyncTest(
            .GET, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
            },
            afterResponse: { res in
                #expect(res.status == expected, "\(note) — got \(res.status)")
            })
    }

    // MARK: - Cross-course staff must be denied (the #1103 exposure)

    @Test func outsiderCannotReadEditorEndpoints() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let id = fx.assignmentID
            for path in [
                "/instructor/\(id)/suite",
                "/instructor/\(id)/files/solution",
                "/instructor/\(id)/files/notebook",
                "/instructor/\(id)/files/item?name=anything.py",
                "/instructor/\(id)/scripts/publictest_a.py",
                "/instructor/\(id)/achievements",
                "/instructor/\(id)/datasets",
                "/instructor/\(id)/global-variables",
                "/instructor/\(id)/edit",
                "/instructor/\(id)/submissions",
                "/instructor/\(id)/students/\(UUID().uuidString)/history",
            ] {
                try await expectStatus(
                    path, cookie: fx.outsiderCookie, .forbidden,
                    "a TA of another course must not read \(path)")
            }
        }
    }

    @Test func outsiderCannotReadDraftEndpoints() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            for path in [
                "/instructor/new/draft/suite?draftID=\(fx.draftID)",
                "/instructor/new/draft/files/item?draftID=\(fx.draftID)&name=anything.py",
            ] {
                try await expectStatus(
                    path, cookie: fx.outsiderCookie, .forbidden,
                    "a TA of another course must not read \(path)")
            }
        }
    }

    // MARK: - Enrolled staff of the owning course keep access

    @Test func insiderTACanStillReadSuiteAndDraft() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            try await expectStatus(
                "/instructor/\(fx.assignmentID)/suite", cookie: fx.insiderCookie, .ok,
                "a TA of the owning course may read the suite")
            try await expectStatus(
                "/instructor/new/draft/suite?draftID=\(fx.draftID)", cookie: fx.insiderCookie, .ok,
                "a TA of the owning course may read the draft suite")
        }
    }

    // MARK: - Admin bypass survives

    @Test func adminCanReadWithoutEnrollment() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let adminCookie = try await loginUser(
                username: "read_auth_admin", password: "pw", role: "admin", on: app)
            try await expectStatus(
                "/instructor/\(fx.assignmentID)/suite", cookie: adminCookie, .ok,
                "an admin may read any course's suite")
        }
    }
}
