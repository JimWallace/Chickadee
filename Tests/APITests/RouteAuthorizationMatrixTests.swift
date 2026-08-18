// Tests/APITests/RouteAuthorizationMatrixTests.swift
//
// #1112 — the web-side structural authorization guard, the sibling of
// MCPAuthorizationCoverageTests. The MCP surface scans every ContentTool
// source and fails the build if a tool skips authorization; the web side had
// only per-route spot suites, which are silent about the next route someone
// adds with an unauthorized loader (the class of miss that produced #1103).
//
// This test walks the live route table (`app.routes.all`), takes every
// parameterized route under `/instructor` and `/courses`, and substitutes real
// fixture IDs into the path parameters. It then asserts two independent
// things:
//
//   (A) COURSE IDENTITY — staff of a *different* course are denied on every
//       route, whatever their role there. Authority is per-course.
//   (B) ROLE RANK — every route's declared floor is crossed with
//       `CourseRole.allCases`: a persona enrolled in the OWNING course at role
//       R must be denied where `R < floor` and must NOT be denied where
//       `R >= floor`.
//
// Both dimensions are DISCOVERED rather than remembered. A new route with a
// parameter the matrix doesn't know fails the walk until a fixture value is
// added; a new route with no declared floor fails until someone declares it;
// and a new `CourseRole` rung gets its denial row from `allCases` with no edit
// here.
//
// WHY (B) EXISTS (the #1448 fitness-function finding). The matrix used to
// cross every route with exactly two personas — a student of the owning course
// and an instructor of a different course — and `.ta` appeared nowhere in it.
// An instructor-only route that forgot its `.instructor` floor passed both
// checks, because a TA of the owning course is neither persona; the TA boundary
// rested on eight hand-written spot tests in `TARoleRouteTests`, which by
// construction only covered routes someone remembered to write. That is the
// "enumerated rather than discovered, fails open" shape `LanguageConformanceMatrixTests`
// was built to escape, sitting on the dimension where the failure mode is
// access to another course's student data. Crossing the discovered route table
// with `allCases` replaced the remembered cases with a derived matrix — and
// immediately found three routes whose floor was missing (see
// `CourseAdminRoutes+Sections.swift`).
//
// HOW A DENIAL IS RECOGNISED, and why it differs per dimension. For the
// cross-course personas, 404 is a legitimate denial: the handler scoped its
// lookup to the caller's own course and the resource genuinely isn't in it. For
// a persona enrolled in the OWNING course that reasoning does not apply — the
// scoped lookup succeeds — so the only status the role floor produces is 403
// (`requireCourseWriteAccess`'s `roleTooLow` and `ActiveCourseStaffMiddleware`'s
// area gate both throw exactly `.forbidden`, and every one of the routes floored
// at `.instructor` returns 403, never 404, to a TA of the owning course). The
// role rows therefore assert on 403 specifically, and treat a 404 as a fixture
// gap — which `fixtureUnresolvedForStaff` below keeps enumerated rather than
// tolerated everywhere, so the positive case cannot quietly pass on an
// unrelated 404.
//
// The two halves of (B) are each other's control: if the fixture were broken —
// persona not enrolled, active course unresolved — every route would 403 and
// the ALLOWED half would fail loudly, so the DENIED half can never be
// vacuously green.

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

    // MARK: - Personas

    /// One logged-in actor: the session cookie plus a CSRF token bound to it.
    private struct Actor {
        let cookie: String
        let csrf: String
    }

    /// Logs `username` in and enrolls them in `courseID` at `role`. The account's
    /// deployment role is always the plain `user` rung, so every persona's
    /// authority comes from the enrollment row alone — which is what makes this
    /// matrix a test of *per-course* authority rather than of the global role.
    private func makeActor(
        username: String, role: CourseRole, courseID: UUID
    ) async throws -> Actor {
        let cookie = try await loginUser(username: username, password: "pw", role: "user", on: app)
        let user = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == username).first())
        try await APICourseEnrollment(
            userID: try user.requireID(), courseID: courseID, role: role
        ).save(on: app.db)
        let (csrf, session) = try await csrfFields(for: "/", cookie: cookie, on: app)
        return Actor(cookie: session, csrf: csrf)
    }

    /// Two `.closed` courses. OWNED holds every target resource; `roleActors`
    /// holds one persona per `CourseRole.allCases` enrolled in OWNED, and the
    /// outsider is an *instructor of OTHER only* — so they clear the
    /// `/instructor` area gate for their own course but must be denied on
    /// OWNED's resources. `.closed` keeps login from auto-enrolling anyone
    /// anywhere else, which is what makes each persona's single enrollment
    /// their active course.
    private final class Fixture {
        let ownedCourseID: UUID
        let roleActors: [CourseRole: Actor]
        let outsider: Actor
        var resourceCounter = 0

        init(ownedCourseID: UUID, roleActors: [CourseRole: Actor], outsider: Actor) {
            self.ownedCourseID = ownedCourseID
            self.roleActors = roleActors
            self.outsider = outsider
        }
    }

    private func makeFixture() async throws -> Fixture {
        let owned = try await makeTestCourse(on: app, code: "AMOWN", name: "Owned Course", mode: .closed)
        let other = try await makeTestCourse(on: app, code: "AMOTH", name: "Other Course", mode: .closed)
        let ownedID = try owned.requireID()

        var actors: [CourseRole: Actor] = [:]
        for role in CourseRole.allCases {
            actors[role] = try await makeActor(
                username: "authz_\(role.rawValue)", role: role, courseID: ownedID)
        }

        let outsiderCookie = try await loginUser(
            username: "authz_outsider", password: "pw", role: "user", on: app)
        let outsider = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "authz_outsider").first())
        try await APICourseEnrollment(
            userID: try outsider.requireID(), courseID: try other.requireID(), role: .instructor
        ).save(on: app.db)
        let (outsiderCSRF, outsiderSession) = try await csrfFields(
            for: "/", cookie: outsiderCookie, on: app)

        return Fixture(
            ownedCourseID: ownedID,
            roleActors: actors,
            outsider: Actor(cookie: outsiderSession, csrf: outsiderCSRF))
    }

    // MARK: - Per-probe resources

    /// A fresh set of target resources in OWNED, plus the path-parameter values
    /// that address them.
    ///
    /// The ALLOWED direction re-mints these before every probe. It has to: an
    /// allowed request is a request that *runs*, and several of them mutate the
    /// very resources the rest of the walk addresses. Measured on a single
    /// shared fixture — `POST /instructor/:assignmentID/delete` returns 303 and
    /// every later `:assignmentID` route then 404s, and
    /// `POST /instructor/content-items/:id/delete` does the same to the two
    /// content-item routes behind it. Those 404s are indistinguishable from a
    /// route that legitimately hides a resource, so the walk would be reading
    /// its own exhaust. The DENIED direction needs no freshness — a denied
    /// request changes nothing — and keeps one resource set for the whole walk.
    private func freshResources(_ fx: Fixture) async throws -> [String: String] {
        fx.resourceCounter += 1
        let tag = "\(fx.resourceCounter)"
        let courseID = fx.ownedCourseID

        try await makeTestSetup(on: app, id: "authz_setup_\(tag)", courseID: courseID)
        // A draft is a setup row with no assignment parent; the draft routes
        // resolve it from the `draftID` QUERY parameter, appended below.
        try await makeTestSetup(on: app, id: "authz_draft_\(tag)", courseID: courseID)
        // The title has to vary: the slug is derived from it and is unique per
        // course, so a re-minted resource set would collide with its predecessor.
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: "authz_setup_\(tag)", courseID: courseID,
            title: "Authz Matrix \(tag)")

        // The routes that take a `:studentID` / `:userID` act ON a student
        // rather than as one, so the target is its own account: an allowed
        // `POST /courses/:courseID/unenroll/:userID` would otherwise unenroll a
        // persona mid-walk.
        let target = try await makeTestUser(on: app, username: "authz_target_\(tag)")
        let targetID = try target.requireID()
        try await APICourseEnrollment(userID: targetID, courseID: courseID, role: .student)
            .save(on: app.db)

        let submission = APISubmission(
            id: "sub_authz_\(tag)",
            testSetupID: "authz_setup_\(tag)",
            zipPath: app.submissionsDirectory + "sub_authz_\(tag).zip",
            attemptNumber: 1,
            status: "complete",
            userID: targetID,
            kind: APISubmission.Kind.student
        )
        try await submission.save(on: app.db)
        let section = APICourseSection(name: "Authz Section", sortOrder: 0, courseID: courseID)
        try await section.save(on: app.db)
        // A content item in OWNED so the /instructor/content-items/:id routes
        // reach their per-resource write gate (rather than 404ing).
        let contentItem = APICourseContentItem(
            courseID: courseID, sortOrder: 0, title: "Authz Material")
        try await contentItem.save(on: app.db)
        // A real pending pre-enrollment, so the two /courses/:courseID/pre-*
        // routes resolve a row instead of 404ing an authorized caller.
        let preEnrollment = APIPreEnrollment(
            courseID: courseID, username: "authz_pending_\(tag)")
        try await preEnrollment.save(on: app.db)

        return [
            // Every path parameter that appears under /instructor or /courses.
            // A new route introducing a NEW parameter fails the walk below until
            // a fixture value is added here — that failure is the guard staying
            // exhaustive.
            "assignmentID": assignment.publicID,
            "courseID": courseID.uuidString,
            "userID": targetID.uuidString,
            "studentID": targetID.uuidString,
            "submissionID": "sub_authz_\(tag)",
            "setupID": "authz_setup_\(tag)",
            "sectionID": try section.requireID().uuidString,
            // The /instructor/content-items/:id/{edit,delete,section} routes.
            "id": try contentItem.requireID().uuidString,
            // The content-items/:id/attachments/:attachmentID/delete route
            // resolves and authorizes the item by :id before it reads
            // :attachmentID, so any valid UUID denies a non-owner.
            "attachmentID": UUID().uuidString,
            "preEnrollmentID": try preEnrollment.requireID().uuidString,
            "filename": "publictest_authz.py",
            // Not a path parameter — the draft editor routes name no resource in
            // their path and resolve it from `?draftID=`, appended in `concretePath`.
            "__draftID": "authz_draft_\(tag)",
        ]
    }

    // MARK: - Route walk

    /// A discovered route, kept in its abstract form so a concrete path can be
    /// built from any resource set.
    private struct MatrixEntry {
        let method: HTTPMethod
        let components: [String]
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

    /// The per-course role each walked route requires, stated once, here.
    ///
    /// This is a *declared* map rather than a scan of the handlers for
    /// `requireCourseRole(atLeast:)`, and deliberately so: inferring the floor
    /// from the implementation would make the test agree with whatever the code
    /// does, including nothing at all — a route whose gate is spelled
    /// differently, or missing, would read as having no floor and pass. The
    /// floor is a human judgement about what the route *is*, so it is written
    /// down and the code is checked against it. The route table stays
    /// discovered, so the map cannot go stale silently: a walked route with no
    /// entry fails the walk by name.
    ///
    /// The convention it encodes is the one stated on `evaluateCourseWrite`:
    ///   `.ta`         — assignment CONTENT and grading.
    ///   `.instructor` — course LIFECYCLE and structure: enrollment/roster/staff,
    ///                   assignment create/delete/open/close, sections, archive,
    ///                   BrightSpace binding.
    private static let declaredFloors: [String: CourseRole] = [
        // MARK: Assignment content + grading — `.ta`
        "GET /instructor/:assignmentID/edit": .ta,
        "GET /instructor/:assignmentID/workbench": .ta,
        "POST /instructor/:assignmentID/edit/save": .ta,
        "GET /instructor/:assignmentID/files/notebook": .ta,
        "GET /instructor/:assignmentID/files/solution": .ta,
        "GET /instructor/:assignmentID/files/item": .ta,
        "POST /instructor/:assignmentID/create-solution": .ta,
        "POST /instructor/:assignmentID/compute-expected": .ta,
        "GET /instructor/:assignmentID/scripts/:filename": .ta,
        "PUT /instructor/:assignmentID/scripts/:filename": .ta,
        "POST /instructor/:assignmentID/scripts": .ta,
        "DELETE /instructor/:assignmentID/scripts/:filename": .ta,
        "GET /instructor/:assignmentID/suite": .ta,
        "PUT /instructor/:assignmentID/suite": .ta,
        "PUT /instructor/:assignmentID/time-limit": .ta,
        "POST /instructor/:assignmentID/suite-sections": .ta,
        "POST /instructor/:assignmentID/suite-sections/reorder": .ta,
        "POST /instructor/:assignmentID/suite-sections/:sectionID/rename": .ta,
        "POST /instructor/:assignmentID/suite-sections/:sectionID/delete": .ta,
        "POST /instructor/:assignmentID/suite-sections/:sectionID/variables": .ta,
        "GET /instructor/:assignmentID/global-variables": .ta,
        "PUT /instructor/:assignmentID/global-variables": .ta,
        "GET /instructor/:assignmentID/datasets": .ta,
        "PUT /instructor/:assignmentID/datasets": .ta,
        "GET /instructor/:assignmentID/achievements": .ta,
        "PUT /instructor/:assignmentID/achievements": .ta,
        // Ungraded course material is content authoring, not course structure —
        // the split stated in `CourseAdminRoutes+ContentItems.swift`.
        "POST /instructor/content-items/:id/edit": .ta,
        "POST /instructor/content-items/:id/delete": .ta,
        "POST /instructor/content-items/:id/section": .ta,
        "POST /instructor/content-items/:id/attachments/:attachmentID/delete": .ta,

        // MARK: Grading + individual accommodations — `.ta`
        // A per-student extension / grade override / retest is an individual
        // accommodation, sibling to grading, not a course-wide deadline change.
        "GET /instructor/:assignmentID/submissions": .ta,
        "GET /instructor/:assignmentID/students/:studentID/history": .ta,
        "POST /instructor/:assignmentID/submissions/:submissionID/retest": .ta,
        "POST /instructor/:assignmentID/retest": .ta,
        "POST /instructor/:assignmentID/students/:studentID/reset-notebook": .ta,
        "POST /instructor/:assignmentID/students/:studentID/grade-override": .ta,
        "POST /instructor/:assignmentID/students/:studentID/grade-override/delete": .ta,
        "POST /instructor/:assignmentID/students/:studentID/regrant-reveal-token": .ta,

        // MARK: Assignment lifecycle — `.instructor`
        "POST /instructor/:assignmentID/open": .instructor,
        "POST /instructor/:assignmentID/close": .instructor,
        "POST /instructor/:assignmentID/status": .instructor,
        "POST /instructor/:assignmentID/delete": .instructor,
        "POST /instructor/:assignmentID/clone": .instructor,
        "POST /instructor/:assignmentID/secret-reveal": .instructor,
        "POST /instructor/setup/:setupID/delete": .instructor,

        // MARK: BrightSpace binding — `.instructor`
        "POST /instructor/:assignmentID/brightspace": .instructor,
        "POST /instructor/:assignmentID/brightspace/push-all": .instructor,

        // MARK: Course structure — `.instructor`
        // Course sections group assignments; which section an assignment sits in
        // is structure, not content. Matches the MCP twins
        // (`rename_course_section`, `delete_course_section`,
        // `set_assignment_course_section`), which have always been `.instructor`.
        "POST /instructor/sections/:sectionID/rename": .instructor,
        "POST /instructor/sections/:sectionID/delete": .instructor,
        "POST /instructor/:assignmentID/section": .instructor,

        // MARK: Enrollment, roster + staff — `.instructor`
        "POST /courses/:courseID/enrollment-mode": .instructor,
        "POST /courses/:courseID/enroll-csv": .instructor,
        "POST /courses/:courseID/unenroll/:userID": .instructor,
        "POST /courses/:courseID/pre-unenroll/:preEnrollmentID": .instructor,
        "POST /courses/:courseID/pre-enroll/:preEnrollmentID/register": .instructor,
        "POST /courses/:courseID/role/:userID": .instructor,
        "POST /courses/:courseID/staff": .instructor,

        // MARK: Unpublished-draft editing — `.instructor`
        // A draft has no assignment parent yet, so editing one is creating an
        // assignment (`loadDraftSetupForWrite`), which is lifecycle.
        "DELETE /instructor/new/draft/scripts/:filename": .instructor,
        "POST /instructor/new/draft/suite-sections/:sectionID/rename": .instructor,
        "POST /instructor/new/draft/suite-sections/:sectionID/delete": .instructor,
        "POST /instructor/new/draft/suite-sections/:sectionID/variables": .instructor,
    ]

    /// Walked routes where a caller who IS authorized still gets a 404, because
    /// the handler resolves a sub-resource the fixture does not materialize
    /// *after* it has authorized. Each entry is a blind spot in the ALLOWED
    /// direction, so keep this list SHORT and justified — a new route landing
    /// here means the fixture needs enriching, not that the route is fine. The
    /// 403 assertion still applies to every entry, so an authorization denial
    /// cannot hide in here.
    private static let fixtureUnresolvedForStaff: Set<String> = [
        // `makeTestSetup` writes a minimal EMPTY zip, so no script file exists
        // inside it to read or delete. Enriching it means shelling out to
        // /usr/bin/zip (`writeZipFixture`), and putting a subprocess in the
        // authorization suite buys a flake surface — the #1139 fork/exec
        // family — for a sub-resource none of these routes authorize on.
        "GET /instructor/:assignmentID/scripts/:filename",
        "DELETE /instructor/:assignmentID/scripts/:filename",
        "DELETE /instructor/new/draft/scripts/:filename",
        // The fixture assignment has a starter notebook but no solution file.
        "GET /instructor/:assignmentID/files/solution",
        // Resolves the destination section from the request BODY, which the
        // walk sends empty.
        "POST /instructor/content-items/:id/section",
        // `:attachmentID` is a synthetic UUID — the item is real, the
        // attachment row is not.
        "POST /instructor/content-items/:id/attachments/:attachmentID/delete",
    ]

    /// Every parameterized route under /instructor or /courses. Records an issue
    /// (fails the test) for any route whose parameter the fixture map doesn't
    /// know, or whose floor nobody has declared.
    private func enumerateResourceRoutes(paramValues: [String: String]) -> [MatrixEntry] {
        var entries: [MatrixEntry] = []
        for route in app.routes.all {
            guard let first = route.path.first, case .constant(let root) = first,
                root == "instructor" || root == "courses"
            else { continue }

            let display = "\(route.method.rawValue) /" + route.path.map(\.description).joined(separator: "/")
            var components: [String] = []
            var sawParameter = false
            var unresolved: [String] = []
            for component in route.path {
                switch component {
                case .constant(let value):
                    components.append(value)
                case .parameter(let name):
                    sawParameter = true
                    if paramValues[name] != nil {
                        components.append(":" + name)
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
                    RouteAuthorizationMatrixTests.freshResources() so the route stays covered \
                    by the cross-course denial guard (#1112).
                    """)
                continue
            }
            guard sawParameter else { continue }
            guard !Self.allowlisted.contains(display) else { continue }
            guard Self.declaredFloors[display] != nil else {
                Issue.record(
                    """
                    \(display) declares no per-course role floor. Add it to \
                    RouteAuthorizationMatrixTests.declaredFloors — `.ta` for assignment \
                    content and grading, `.instructor` for course lifecycle and structure \
                    (enrollment/roster/staff, assignment create/delete/open/close, sections, \
                    archive, BrightSpace binding), matching the convention on \
                    `evaluateCourseWrite`. The matrix then holds the route to it. If the \
                    route is genuinely open to any authenticated user, allowlist it instead \
                    and say why.
                    """)
                continue
            }
            entries.append(
                MatrixEntry(method: route.method, components: components, display: display))
        }
        return entries
    }

    /// Substitutes one resource set into a discovered route.
    private func concretePath(_ entry: MatrixEntry, _ paramValues: [String: String]) -> String {
        let parts = entry.components.map { component -> String in
            guard component.hasPrefix(":") else { return component }
            return paramValues[String(component.dropFirst())] ?? component
        }
        var path = "/" + parts.joined(separator: "/")
        // The draft editor routes resolve their resource from the `draftID`
        // QUERY parameter (the path names no resource), so the matrix supplies
        // the owned course's draft the same way the editor would.
        if entry.components.starts(with: ["instructor", "new", "draft"]),
            let draftID = paramValues["__draftID"]
        {
            path += "?draftID=\(draftID)"
        }
        return path
    }

    private func status(
        _ entry: MatrixEntry, path: String, actor: Actor
    ) async throws -> HTTPStatus {
        var observed: HTTPStatus = .internalServerError
        try await app.asyncTest(
            entry.method, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: actor.cookie)
                if entry.method != .GET {
                    req.headers.add(name: "x-csrf-token", value: actor.csrf)
                    req.headers.contentType = .urlEncodedForm
                    req.body = ByteBuffer(string: "")
                }
            },
            afterResponse: { res in observed = res.status })
        return observed
    }

    // 401/403 = the gate fired; 404 = the handler correctly scoped the lookup to
    // the caller's own course (e.g. "assignment not in your active course").
    // Anything else — a 2xx render, a 3xx action-succeeded redirect, or a 400
    // body error reached before authorization — is a hole.
    private static let deniedStatuses: Set<HTTPStatus> = [.unauthorized, .forbidden, .notFound]

    // MARK: - (A) Course identity

    @Test func crossCourseStaffAreDeniedOnEveryResourceRoute() async throws {
        try await withApp(app) { _ in
            let fx = try await makeFixture()
            let params = try await freshResources(fx)
            let entries = enumerateResourceRoutes(paramValues: params)
            #expect(
                entries.count >= 40,
                "route walk found only \(entries.count) parameterized /instructor + /courses routes — did the filter break?"
            )
            for entry in entries {
                let observed = try await status(
                    entry, path: concretePath(entry, params), actor: fx.outsider)
                #expect(
                    Self.deniedStatuses.contains(observed),
                    "staff of another course must be denied on \(entry.display) — got \(observed)")
            }
        }
    }

    // MARK: - (B) Role rank, derived over `CourseRole.allCases`

    /// Every role below a route's declared floor must be denied on it.
    ///
    /// Derived: `allCases` supplies the rows, the route walk supplies the
    /// columns, and the comparison is `role < floor` — so a fourth rung would
    /// get its denial row here with no edit to this test. Today the rows are
    /// `.student` (below every walked route's floor — the whole `/instructor`
    /// area is TA+) and `.ta` (below the `.instructor` routes only); `.instructor`
    /// contributes no denials because nothing floors above it, which is why its
    /// coverage lives in the ALLOWED test below rather than here.
    ///
    /// A denied request mutates nothing, so one resource set serves the walk.
    @Test func rolesBelowARoutesFloorAreDenied() async throws {
        try await withApp(app) { _ in
            let fx = try await makeFixture()
            let params = try await freshResources(fx)
            let entries = enumerateResourceRoutes(paramValues: params)
            var checks = 0
            for role in CourseRole.allCases {
                let actor = try #require(fx.roleActors[role])
                for entry in entries {
                    let floor = try #require(Self.declaredFloors[entry.display])
                    guard role < floor else { continue }
                    checks += 1
                    let observed = try await status(
                        entry, path: concretePath(entry, params), actor: actor)
                    #expect(
                        Self.deniedStatuses.contains(observed),
                        """
                        a caller holding \(role.rawValue) in the owning course must be denied on \
                        \(entry.display) (declared floor: \(floor.rawValue)) — got \(observed). \
                        Either the route is missing its floor or the declared floor is wrong.
                        """)
                }
            }
            // Guards against a silently empty matrix — e.g. a floor map that
            // stopped matching the walked display strings.
            #expect(checks >= 60, "role-denial matrix ran only \(checks) checks — did the floor map stop matching?")
        }
    }

    /// Every role at or above a route's declared floor must NOT be denied on it.
    ///
    /// This is the half that catches an over-tightened floor, and it is what
    /// makes the denial half meaningful: if the fixture were broken, every route
    /// would 403 here and this test would fail rather than the denial test
    /// passing vacuously.
    ///
    /// It asserts on 403 specifically. For a persona enrolled in the OWNING
    /// course, 403 is the only status a role floor produces — the scoped lookups
    /// that make 404 a legitimate denial for the cross-course personas all
    /// succeed here — so a 404 means the fixture didn't materialize a
    /// sub-resource, and the routes where that is true are enumerated in
    /// `fixtureUnresolvedForStaff` rather than tolerated everywhere.
    @Test func rolesAtOrAboveARoutesFloorAreNotDenied() async throws {
        try await withApp(app) { _ in
            let fx = try await makeFixture()
            let entries = enumerateResourceRoutes(paramValues: try await freshResources(fx))
            var checks = 0
            for role in CourseRole.allCases {
                let actor = try #require(fx.roleActors[role])
                for entry in entries {
                    let floor = try #require(Self.declaredFloors[entry.display])
                    guard role >= floor else { continue }
                    checks += 1
                    // An allowed request RUNS, and several mutate the resources
                    // the walk addresses — so each probe gets its own set.
                    let params = try await freshResources(fx)
                    let observed = try await status(
                        entry, path: concretePath(entry, params), actor: actor)
                    #expect(
                        observed != .forbidden && observed != .unauthorized,
                        """
                        a caller holding \(role.rawValue) in the owning course must NOT be denied on \
                        \(entry.display) (declared floor: \(floor.rawValue)) — got \(observed). \
                        Either the route's floor is tighter than declared, or the declared \
                        floor is wrong.
                        """)
                    guard !Self.fixtureUnresolvedForStaff.contains(entry.display) else { continue }
                    #expect(
                        observed != .notFound,
                        """
                        \(entry.display) 404s a caller holding \(role.rawValue) in the owning course, so the \
                        ALLOWED case above proves nothing for it. Give the fixture the \
                        resource this route resolves after authorizing, or — if that is \
                        impractical — add it to fixtureUnresolvedForStaff with the reason.
                        """)
                }
            }
            #expect(checks >= 80, "role-allowed matrix ran only \(checks) checks — did the floor map stop matching?")
        }
    }
}
