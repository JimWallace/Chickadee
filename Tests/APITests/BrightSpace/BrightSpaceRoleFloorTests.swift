// Tests/APITests/BrightSpace/BrightSpaceRoleFloorTests.swift
//
// #2710 — the BrightSpace tab's course-level actions are `.instructor` actions
// (docs/multi-course-roles.md, "BrightSpace binding"). `ActiveCourseStaffMiddleware`
// admits a TA to `/instructor`, so each handler states its own floor. A TA is
// refused; an instructor is not; an instructor of an archived course is refused
// too, because an archived course is read-only.
//
// Two actions stay open to a TA: `disconnect` acts on the caller's own LEARN
// account, not the course, and `test` only reads.
//
// The routes take no path parameter, so `RouteAuthorizationMatrixTests` does
// not walk them. `InstructorParameterlessRouteFloorTests` holds the floor for
// every such route; these tests check the BrightSpace outcomes in detail.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2))) final class BrightSpaceRoleFloorTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-bs-role-floor")
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

    private func post(_ path: String, as actor: Actor, fields: [String: String] = [:]) async throws -> HTTPStatus {
        var observed: HTTPStatus = .internalServerError
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: actor.cookie)
                var form = fields
                form["_csrf"] = actor.csrf
                try req.content.encode(form, as: .urlEncodedForm)
            },
            afterResponse: { res in observed = res.status })
        return observed
    }

    /// The course-level actions, each with a body that gets past form decoding.
    static let instructorActions: [(path: String, fields: [String: String])] = [
        ("/instructor/brightspace/connect", ["userID": "vu", "userKey": "vk"]),
        ("/instructor/brightspace/use-my-identity", [:]),
        ("/instructor/brightspace/bind-org-unit", ["orgUnitID": "12345"]),
        ("/instructor/brightspace/auto-map", [:]),
        ("/instructor/brightspace/sync-now", [:]),
        ("/instructor/brightspace/reconcile-now", [:]),
    ]

    @Test func aTAIsRefusedEveryCourseLevelAction() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("BSTA")
            let ta = try await actor("bs_ta", role: .ta, courseID: courseID)
            for action in Self.instructorActions {
                let status = try await post(action.path, as: ta, fields: action.fields)
                #expect(status == .forbidden, "TA POST \(action.path) returned \(status)")
            }
        }
    }

    @Test func aTACannotRebindTheOrgUnit() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("BSBIND")
            let ta = try await actor("bs_binder_ta", role: .ta, courseID: courseID)
            let before = try #require(try await APICourse.find(courseID, on: app.db))
            before.brightspaceOrgUnitID = "999"
            try await before.save(on: app.db)

            let status = try await post("/instructor/brightspace/bind-org-unit", as: ta, fields: ["orgUnitID": ""])
            #expect(status == .forbidden)
            let after = try #require(try await APICourse.find(courseID, on: app.db))
            #expect(after.brightspaceOrgUnitID == "999")
        }
    }

    @Test func anInstructorIsNotRefused() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("BSINS")
            let instructor = try await actor("bs_instructor", role: .instructor, courseID: courseID)
            for action in Self.instructorActions {
                let status = try await post(action.path, as: instructor, fields: action.fields)
                // BrightSpace is not configured in the test app, so each action
                // flashes its reason and redirects back to the tab.
                #expect(status == .seeOther, "instructor POST \(action.path) returned \(status)")
            }
        }
    }

    @Test func anInstructorOfAnArchivedCourseIsRefused() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("BSARC", archived: true)
            let instructor = try await actor("bs_archived_instructor", role: .instructor, courseID: courseID)
            for action in Self.instructorActions {
                let status = try await post(action.path, as: instructor, fields: action.fields)
                #expect(status == .forbidden, "archived POST \(action.path) returned \(status)")
            }
        }
    }

    /// The tab renders the controls each viewer can use: a TA sees none of the
    /// course-level actions, an instructor sees all of them.
    @Test func theTabHidesTheCourseLevelActionsFromATA() async throws {
        try await withApp(app) { _ in
            app.brightSpaceAppCredentials = BrightSpaceAppCredentials(
                baseURL: "https://learn.test", appID: "a", appKey: "k", debounceSecs: 90)
            let courseID = try await course("BSPAGE")
            let linked = try #require(try await APICourse.find(courseID, on: app.db))
            linked.brightspaceOrgUnitID = "12345"
            try await linked.save(on: app.db)
            try await makeTestSetup(on: app, id: "bs_page_setup", courseID: courseID)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "bs_page_setup", courseID: courseID, title: "Lab One")
            let ta = try await actor("bs_page_ta", role: .ta, courseID: courseID)
            let instructor = try await actor("bs_page_instructor", role: .instructor, courseID: courseID)
            let actions = [
                "/instructor/brightspace/connect", "/instructor/brightspace/sync-now",
                "/instructor/brightspace/reconcile-now", "/instructor/brightspace/auto-map",
                "/instructor/\(assignment.publicID)/brightspace/push-all",
            ]

            let taPage = try await getHTML("/instructor/brightspace", cookie: ta.cookie, on: app)
            let instructorPage = try await getHTML("/instructor/brightspace", cookie: instructor.cookie, on: app)
            for action in actions {
                #expect(!taPage.contains(action), "a TA sees \(action)")
                #expect(instructorPage.contains(action), "an instructor does not see \(action)")
            }
            let note = "Only course instructors can change the LEARN connection."
            #expect(taPage.contains(note))
            #expect(!instructorPage.contains(note))
        }
    }

    @Test func aTAKeepsTheAccountAndReadOnlyActions() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("BSOWN")
            let ta = try await actor("bs_own_ta", role: .ta, courseID: courseID)
            #expect(try await post("/instructor/brightspace/disconnect", as: ta) == .seeOther)
            #expect(try await post("/instructor/brightspace/test", as: ta) == .ok)
        }
    }
}
