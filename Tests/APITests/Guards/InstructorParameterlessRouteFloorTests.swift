// Tests/APITests/Guards/InstructorParameterlessRouteFloorTests.swift
//
// #2710 — the sibling of `RouteAuthorizationMatrixTests` for the routes it does
// not walk. The matrix takes only routes with a path parameter, because it
// probes cross-course access by substituting another course's IDs. A route
// under `/instructor` with no path parameter acts on the caller's ACTIVE
// course, so it has no cross-course dimension, but it still has a role floor.
// `ActiveCourseStaffMiddleware` admits every TA to `/instructor`, and each
// mutating handler must state its finer floor itself. Six BrightSpace
// handlers did not, and no test saw it.
//
// This test walks the live route table, takes every mutating route under
// `/instructor` with no path parameter, and requires a declared floor for
// each. It then posts to each route as a TA of the active course:
//
//   - a route floored at `.instructor` must answer 403;
//   - a route floored at `.ta` must not answer 403.
//
// The `.ta` half is the control. If the persona were broken (not enrolled,
// no active course), every route would answer 403 and that half would fail.
//
// A route that is new, and has no entry, fails the walk by name.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class InstructorParameterlessRouteFloorTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-instr-floor")
    }

    /// The per-course role each route requires, stated once, here. The
    /// convention is the one on `evaluateCourseWrite`:
    ///   `.ta`         — assignment content and grading.
    ///   `.instructor` — course lifecycle and structure, BrightSpace binding.
    private static let declaredFloors: [String: CourseRole] = [
        // MARK: Assignment content and grading — `.ta`
        "POST /instructor/content-items": .ta,
        "POST /instructor/content-items/reorder": .ta,
        // Every reorder kind floors at `SortOrderRenumbering.roleFloor`.
        "POST /instructor/section-items/reorder": .ta,
        "POST /instructor/reorder": .ta,
        "POST /instructor/sections/reorder": .ta,
        "POST /instructor/scan-notebook": .ta,
        "POST /instructor/achievements/recompute": .ta,
        "PUT /instructor/achievements/rows": .ta,
        "POST /instructor/datasets": .ta,
        "POST /instructor/datasets/delete": .ta,
        "POST /instructor/datasets/dictionary": .ta,
        "POST /instructor/datasets/metadata": .ta,
        "POST /instructor/datasets/publish": .ta,
        "POST /instructor/datasets/versions": .ta,
        "POST /instructor/mcp/attestation": .ta,
        // A per-student slip-day change is an individual accommodation.
        "POST /instructor/slip-days/adjust": .ta,
        "POST /instructor/slip-days/refund": .ta,
        "POST /instructor/lti-grades/push-all": .ta,
        // The caller's own LEARN account, not the course; and a read.
        "POST /instructor/brightspace/disconnect": .ta,
        "POST /instructor/brightspace/test": .ta,

        // MARK: BrightSpace binding and sync identity — `.instructor` (#2710)
        "POST /instructor/brightspace/connect": .instructor,
        "POST /instructor/brightspace/use-my-identity": .instructor,
        "POST /instructor/brightspace/bind-org-unit": .instructor,
        "POST /instructor/brightspace/auto-map": .instructor,
        "POST /instructor/brightspace/sync-now": .instructor,
        "POST /instructor/brightspace/reconcile-now": .instructor,
        "POST /instructor/lti-grades/transport": .instructor,
        "POST /instructor/lti-grades/link-students": .instructor,

        // MARK: Course structure and settings — `.instructor`
        "POST /instructor/new-term": .instructor,
        "POST /instructor/sections": .instructor,
        "POST /instructor/slip-days/settings": .instructor,
        "POST /instructor/mcp": .instructor,
        "POST /instructor/github/bind": .instructor,
        "POST /instructor/github/unbind": .instructor,
        "POST /instructor/github/templates": .instructor,
        "POST /instructor/github/archive": .instructor,
        "POST /instructor/groups/sets": .instructor,
        "POST /instructor/groups/add": .instructor,
        "POST /instructor/groups/remove": .instructor,
        "POST /instructor/groups/import": .instructor,
        "POST /instructor/groups/membership": .instructor,
        "POST /instructor/groups/source": .instructor,
        "POST /instructor/groups/sync": .instructor,

        // MARK: Assignment creation — `.instructor`
        "POST /instructor": .instructor,
        "POST /instructor/new/save": .instructor,
        "POST /instructor/new/draft": .instructor,
        "POST /instructor/new/draft/scripts": .instructor,
        "POST /instructor/new/draft/suite-sections": .instructor,
        "POST /instructor/new/draft/suite-sections/reorder": .instructor,
        "PUT /instructor/new/draft/datasets": .instructor,
        "PUT /instructor/new/draft/suite": .instructor,
    ]

    /// Routes floored at `.instructor` that read the request (its body, its
    /// `draftID`, or the registered GitHub App) before the floor check. An empty
    /// post stops at that read with a 4xx, so the probe cannot prove the floor.
    /// For these, the probe asserts only that the TA's post did not succeed.
    /// Keep the list short: a route here is one this test cannot fully see.
    private static let readsBeforeFloor: Set<String> = [
        // `requireWritableSet` resolves the set from the form first.
        "POST /instructor/groups/add",
        "POST /instructor/groups/remove",
        "POST /instructor/groups/import",
        "POST /instructor/groups/membership",
        // `loadDraftSetupForWrite` reads `draftID` first.
        "POST /instructor/new/draft/scripts",
        "POST /instructor/new/draft/suite-sections",
        "POST /instructor/new/draft/suite-sections/reorder",
        "PUT /instructor/new/draft/datasets",
        "PUT /instructor/new/draft/suite",
        // `requireInstructorCourse` answers 404 when no GitHub App is registered.
        "POST /instructor/github/bind",
        "POST /instructor/github/unbind",
        "POST /instructor/github/templates",
        "POST /instructor/github/archive",
    ]

    /// Routes whose declared floor the handler does not enforce today. The
    /// probe skips them until a fix moves each one out of this list. Keep it
    /// empty: an entry is a known hole.
    private static let knownGaps: Set<String> = []

    private static let mutatingMethods: [HTTPMethod] = [.POST, .PUT, .PATCH, .DELETE]

    /// Every mutating route under `/instructor` that has no path parameter.
    private func parameterlessRoutes() -> [(method: HTTPMethod, path: String, display: String)] {
        app.routes.all.compactMap { route in
            guard Self.mutatingMethods.contains(route.method),
                let first = route.path.first, case .constant("instructor") = first
            else { return nil }
            var parts: [String] = []
            for component in route.path {
                guard case .constant(let value) = component else { return nil }
                parts.append(value)
            }
            let path = "/" + parts.joined(separator: "/")
            return (route.method, path, "\(route.method.rawValue) \(path)")
        }
    }

    @Test func everyParameterlessInstructorWriteDeclaresAFloor() async throws {
        try await withApp(app) { _ in
            let undeclared = parameterlessRoutes().map(\.display).filter { Self.declaredFloors[$0] == nil }
            #expect(
                undeclared.isEmpty,
                """
                These /instructor routes declare no per-course role floor: \(undeclared.sorted()). \
                Add each to InstructorParameterlessRouteFloorTests.declaredFloors: `.ta` for \
                assignment content and grading, `.instructor` for course lifecycle and structure \
                (enrollment, sections, archive, BrightSpace binding).
                """)
        }
    }

    @Test func aTAOfTheActiveCourseMeetsEachDeclaredFloor() async throws {
        try await withApp(app) { _ in
            let ta = try await taOfActiveCourse()
            for route in parameterlessRoutes() {
                guard let floor = Self.declaredFloors[route.display],
                    !Self.knownGaps.contains(route.display)
                else { continue }
                let status = try await status(route.method, route.path, as: ta)
                if Self.readsBeforeFloor.contains(route.display) {
                    #expect(
                        (400..<500).contains(status.code),
                        "TA \(route.display) returned \(status), not a refusal")
                } else if floor > .ta {
                    #expect(status == .forbidden, "TA \(route.display) returned \(status), not 403")
                } else {
                    #expect(status != .forbidden, "TA \(route.display) was refused, but its floor is .ta")
                }
            }
        }
    }

    // MARK: - Helpers

    private struct Actor {
        let cookie: String
        let csrf: String
    }

    /// A TA of one `.closed` course, which is their only course and so their
    /// active one.
    private func taOfActiveCourse() async throws -> Actor {
        let course = try await makeTestCourse(on: app, code: "FLOOR", mode: .closed)
        let cookie = try await loginUser(username: "floor_ta", password: "pw", role: "user", on: app)
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == "floor_ta").first())
        try await APICourseEnrollment(
            userID: try user.requireID(), courseID: try course.requireID(), role: .ta
        ).save(on: app.db)
        let (csrf, session) = try await csrfFields(for: "/", cookie: cookie, on: app)
        return Actor(cookie: session, csrf: csrf)
    }

    /// The status for an empty form post. A floor check that runs before the
    /// body is read answers 403; a 400 or a redirect means the request got past it.
    private func status(_ method: HTTPMethod, _ path: String, as actor: Actor) async throws -> HTTPStatus {
        var observed: HTTPStatus = .internalServerError
        try await app.asyncTest(
            method, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: actor.cookie)
                req.headers.add(name: "x-csrf-token", value: actor.csrf)
                req.headers.contentType = .urlEncodedForm
                req.body = ByteBuffer(string: "")
            },
            afterResponse: { res in observed = res.status })
        return observed
    }
}
