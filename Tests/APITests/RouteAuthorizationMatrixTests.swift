// Tests/APITests/RouteAuthorizationMatrixTests.swift
//
// #1112 — the web-side structural authorization guard, the sibling of
// MCPAuthorizationCoverageTests. The MCP surface scans every ContentTool
// source and fails the build if a tool skips authorization; the web side had
// only per-route spot suites, which are silent about the next route someone
// adds with an unauthorized loader (the class of miss that produced #1103).
//
// This test walks the live route table (`app.routes.all`), takes every
// parameterized route under `/instructor` and `/courses`, substitutes real
// fixture IDs into the path parameters, and asserts the route DENIES
// (401/403/404):
//   (i)  a student of the course that owns the target resources, and
//   (ii) staff (an instructor) of a *different* course.
//
// Route enumeration makes it self-updating: a new route with a parameter the
// matrix doesn't know fails the test with instructions to extend the fixture
// map, and a new resource route that forgets its per-course gate fails with
// the offending route named.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class RouteAuthorizationMatrixTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-authz-matrix")
    }

    private struct Fixture {
        let paramValues: [String: String]
        let outsiderCookie: String
        let outsiderCSRF: String
        let studentCookie: String
        let studentCSRF: String
    }

    /// Two `.closed` courses: OWNED holds every target resource (assignment,
    /// setup, submission, student, course section); the outsider is an
    /// *instructor* of OTHER only (so they pass the /instructor area gate for
    /// their own course but must be denied on OWNED's resources), and the
    /// student is enrolled in OWNED itself.
    private func fixture() async throws -> Fixture {
        let owned = try await makeTestCourse(on: app, code: "AMOWN", name: "Owned Course", mode: .closed)
        let other = try await makeTestCourse(on: app, code: "AMOTH", name: "Other Course", mode: .closed)
        let ownedID = try owned.requireID()

        try await makeTestSetup(on: app, id: "authz_setup", courseID: ownedID)
        // A draft is a setup row with no assignment parent; the draft routes
        // resolve it from the `draftID` QUERY parameter, appended below.
        try await makeTestSetup(on: app, id: "authz_draft", courseID: ownedID)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: "authz_setup", courseID: ownedID, title: "Authz Matrix")

        let studentCookie = try await loginUser(
            username: "authz_student", password: "pw", role: "user", on: app)
        let student = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "authz_student").first())
        let studentID = try student.requireID()
        try await APICourseEnrollment(userID: studentID, courseID: ownedID, role: .student)
            .save(on: app.db)
        let submission = APISubmission(
            id: "sub_authz",
            testSetupID: "authz_setup",
            zipPath: app.submissionsDirectory + "sub_authz.zip",
            attemptNumber: 1,
            status: "complete",
            userID: studentID,
            kind: APISubmission.Kind.student
        )
        try await submission.save(on: app.db)
        let section = APICourseSection(name: "Authz Section", sortOrder: 0, courseID: ownedID)
        try await section.save(on: app.db)

        let outsiderCookie = try await loginUser(
            username: "authz_outsider", password: "pw", role: "user", on: app)
        let outsider = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "authz_outsider").first())
        try await APICourseEnrollment(
            userID: try outsider.requireID(), courseID: try other.requireID(), role: .instructor
        ).save(on: app.db)

        let (outsiderCSRF, outsiderSession) = try await csrfFields(
            for: "/", cookie: outsiderCookie, on: app)
        let (studentCSRF, studentSession) = try await csrfFields(
            for: "/", cookie: studentCookie, on: app)

        return Fixture(
            paramValues: [
                // Every path parameter that appears under /instructor or
                // /courses. A new route introducing a NEW parameter fails the
                // walk below until a fixture value is added here — that
                // failure is the guard staying exhaustive.
                "assignmentID": assignment.publicID,
                "courseID": ownedID.uuidString,
                "userID": studentID.uuidString,
                "studentID": studentID.uuidString,
                "submissionID": "sub_authz",
                "setupID": "authz_setup",
                "sectionID": try section.requireID().uuidString,
                "preEnrollmentID": UUID().uuidString,
                "filename": "publictest_authz.py",
            ],
            outsiderCookie: outsiderSession,
            outsiderCSRF: outsiderCSRF,
            studentCookie: studentSession,
            studentCSRF: studentCSRF)
    }

    private struct MatrixEntry {
        let method: HTTPMethod
        let path: String
        let display: String
    }

    /// Routes under the walked prefixes that are deliberately available to any
    /// authenticated user. Keep this list SHORT and justified — every entry is
    /// a hole the matrix can no longer see.
    private static let allowlisted: Set<String> = [
        // Nav-tab switch (EnrollmentRoutes, any-auth group): verifies the
        // caller's own enrollment and silently no-ops (redirect) when they
        // aren't enrolled in the named course. No cross-course effect.
        "POST /courses/:courseID/activate"
    ]

    /// Every parameterized route under /instructor or /courses, with fixture
    /// values substituted. Records an issue (fails the test) for any route
    /// whose parameter the fixture map doesn't know.
    private func enumerateResourceRoutes(paramValues: [String: String]) -> [MatrixEntry] {
        var entries: [MatrixEntry] = []
        for route in app.routes.all {
            guard let first = route.path.first, case .constant(let root) = first,
                root == "instructor" || root == "courses"
            else { continue }

            let display = "\(route.method.rawValue) /" + route.path.map(\.description).joined(separator: "/")
            var parts: [String] = []
            var sawParameter = false
            var unresolved: [String] = []
            for component in route.path {
                switch component {
                case .constant(let value):
                    parts.append(value)
                case .parameter(let name):
                    sawParameter = true
                    if let value = paramValues[name] {
                        parts.append(value)
                    } else {
                        unresolved.append(name)
                    }
                case .anything, .catchall:
                    unresolved.append("(wildcard)")
                }
            }
            guard unresolved.isEmpty else {
                Issue.record(
                    """
                    \(display) uses path parameter(s) \(unresolved) the authorization \
                    matrix doesn't know. Add a fixture value for it in \
                    RouteAuthorizationMatrixTests.fixture() so the route stays covered \
                    by the cross-course denial guard (#1112).
                    """)
                continue
            }
            guard sawParameter else { continue }
            guard !Self.allowlisted.contains(display) else { continue }
            // The draft editor routes resolve their resource from the
            // `draftID` QUERY parameter (the path names no resource), so the
            // matrix supplies the owned course's draft the same way the
            // editor would.
            var path = "/" + parts.joined(separator: "/")
            if parts.starts(with: ["instructor", "new", "draft"]) {
                path += "?draftID=authz_draft"
            }
            entries.append(
                MatrixEntry(
                    method: route.method,
                    path: path,
                    display: display))
        }
        return entries
    }

    private func expectDenied(
        _ entry: MatrixEntry, cookie: String, csrf: String, actor: String
    ) async throws {
        try await app.asyncTest(
            entry.method, entry.path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                if entry.method != .GET {
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .urlEncodedForm
                    req.body = ByteBuffer(string: "")
                }
            },
            afterResponse: { res in
                // 401/403 = the gate fired; 404 = the handler correctly scoped
                // the lookup to the caller's own course (e.g. "assignment not
                // in your active course"). Anything else — a 2xx render, a 3xx
                // action-succeeded redirect, or a 400 body error reached
                // before authorization — is a hole.
                let denied: Set<HTTPStatus> = [.unauthorized, .forbidden, .notFound]
                #expect(
                    denied.contains(res.status),
                    "\(actor) must be denied on \(entry.display) — got \(res.status)")
            })
    }

    @Test func crossCourseStaffAreDeniedOnEveryResourceRoute() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let entries = enumerateResourceRoutes(paramValues: fx.paramValues)
            #expect(
                entries.count >= 40,
                "route walk found only \(entries.count) parameterized /instructor + /courses routes — did the filter break?"
            )
            for entry in entries {
                try await expectDenied(
                    entry, cookie: fx.outsiderCookie, csrf: fx.outsiderCSRF,
                    actor: "staff of another course")
            }
        }
    }

    @Test func studentsAreDeniedOnEveryInstructorRoute() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture()
            let entries = enumerateResourceRoutes(paramValues: fx.paramValues)
            for entry in entries {
                try await expectDenied(
                    entry, cookie: fx.studentCookie, csrf: fx.studentCSRF,
                    actor: "a student of the owning course")
            }
        }
    }
}
