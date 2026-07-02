// APIServer/Routes/Web/WebRoutes.swift
//
// Browser-facing routes for the Chickadee web UI.
// All routes in this collection require authentication (enforced by RoleMiddleware
// in routes.swift).
//
//   GET  /                          → index.leaf      (assignments)
//   GET  /testsetups/:id/submit     → submit.leaf     (student submission form)
//   POST /testsetups/:id/submit     → save submission, redirect to /submissions/:id
//   GET  /testsetups/:id/notebook   → notebook.leaf   (JupyterLite in-browser editor)
//   GET  /submissions/:id           → submission.leaf (live results)

import Core
import Fluent
import Foundation
import Leaf
import Vapor

struct WebRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(use: index)
        routes.get("testsetups", ":testSetupID", "submit", use: submitForm)
        routes.post("testsetups", ":testSetupID", "submit", use: createSubmission)
        routes.get("testsetups", ":testSetupID", "history", use: submissionHistoryPage)
        routes.get("testsetups", ":testSetupID", "notebook", use: notebookPage)
        routes.get("testsetups", ":testSetupID", "notebook", "source", use: notebookSource)
        routes.post("testsetups", ":testSetupID", "reset-notebook", use: resetOwnNotebook)
        // Self-service "clear cached editor data" page for a wedged kernel
        // (Clear-Site-Data: cache + storage; see WebRoutes+EditorReset.swift).
        routes.get("reset-editor", use: editorResetPage)
        routes.post("reset-editor", use: performEditorReset)
        routes.get("submissions", ":submissionID", use: submissionPage)
    }

    // MARK: - GET /

    // The student dashboard handler dispatches across many distinct
    // page states: no active course → /enroll, instructor-only courses
    // → admin index, no assignments yet → empty-course page, etc.  The
    // heavy phases (per-student grade data, per-setup row build) live in
    // WebRoutes+IndexRows.swift (#1120); what remains here is the state
    // dispatch plus the load/sort/group pipeline.
    @Sendable
    func index(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)

        // Resolve active course and build course-aware user context for tabs.
        let courseState = try await req.resolveActiveCourse(for: user)
        let userContext = CurrentUserContext(
            user: user,
            activeCourse: courseState.active,
            enrolledCourses: courseState.all
        )

        // If the user has no active enrollment but open-mode courses exist → redirect to /enroll.
        // We only redirect when self-enrolment is actually possible; if all courses are closed
        // or auto the /enroll page would be empty and the redirect would be confusing.
        if courseState.active == nil {
            let openCourseCount = try await APICourse.query(on: req.db)
                .filter(\.$isArchived == false)
                .filter(\.$enrollmentModeRaw == CourseEnrollmentMode.open.rawValue)
                .count()
            if openCourseCount > 0 {
                return req.redirect(to: "/enroll")
            }
        }

        // The home dashboard is course-scoped for every role. With no active
        // enrollment we've either already redirected to /enroll (when an open
        // course exists to self-enrol into) or there's nothing this user is
        // affiliated with — render the empty "not enrolled in any courses"
        // dashboard rather than falling through to a deployment-wide assignment
        // list. An admin with no enrollment administers courses from /admin; the
        // home dashboard is never an all-courses view, for any role.
        guard let activeCourseUUID = courseState.activeCourseUUID else {
            return try await req.view.render(
                "index",
                IndexContext(displayGroups: [], hasAny: false, currentUser: userContext)
            ).encodeResponse(for: req)
        }

        let fmt = waterlooDateTimeFormatter()

        // Whether the viewer is staff (TA+ or admin) in the *active* course —
        // drives instructor vs student dashboard rendering. Per-course now, read
        // from the resolved active-course role (#417 Slice G — was the global
        // `user.isInstructor`).
        let isActiveCourseStaff = user.isAdmin || (courseState.active?.role ?? .student) >= .ta

        // Load every assignment in the active course.
        let allAssignments = try await APIAssignment.query(on: req.db)
            .filter(\.$courseID == activeCourseUUID)
            .all()
        let assignmentBySetup = Dictionary(
            allAssignments.map { ($0.testSetupID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // The three independent reads that key off the assignment list run
        // concurrently (helpers in WebRoutes+IndexLoading.swift): per-user
        // extensions, prior engagement (keeps closed assignments visible),
        // and the course sections used to group rows at the bottom of the
        // page.
        async let extensionsFetch = Self.loadExtensionDueDates(
            user: user, allAssignments: allAssignments, db: req.db)
        async let previouslyOpenedFetch = Self.loadPreviouslyOpenedSetupIDs(
            user: user, allAssignments: allAssignments, db: req.db)
        async let sectionsFetch = Self.loadCourseSections(
            activeCourseUUID: courseState.activeCourseUUID, db: req.db)

        let extensionDueAtBySetupID = try await extensionsFetch
        let previouslyOpenedSetupIDs = try await previouslyOpenedFetch

        let setups: [APITestSetup]
        if isActiveCourseStaff {
            // Instructors and admins see every test setup in the active course.
            setups = try await APITestSetup.query(on: req.db)
                .filter(\.$courseID == activeCourseUUID)
                .sort(\.$createdAt, .descending)
                .all()
        } else {
            // Enrolled students see every published assignment in their course:
            // open ones, and ones that were published and have since closed at
            // their deadline — kept on the list (read-only) so recent labs never
            // silently disappear. Preview / scheduled / unpublished-draft
            // assignments stay hidden (see assignmentVisibleToStudentByState).
            let now = Date()
            var visibleSetupIDs = Set(
                allAssignments
                    .filter { assignmentVisibleToStudentByState($0, now: now) }
                    .map(\.testSetupID))
            // An active per-student extension also reveals an assignment that was
            // closed before its deadline (which the by-state rule leaves hidden
            // for everyone else) to the one student who was granted more time.
            for (setupID, extendedDueAt) in extensionDueAtBySetupID
            where studentHasActiveExtension(extensionDueAt: extendedDueAt, now: now) {
                visibleSetupIDs.insert(setupID)
            }
            // Any closed assignment the student already engaged with stays listed
            // too — covers no-deadline assignments the by-state rule can't classify.
            visibleSetupIDs.formUnion(previouslyOpenedSetupIDs)
            guard !visibleSetupIDs.isEmpty else {
                return try await req.view.render(
                    "index",
                    IndexContext(displayGroups: [], hasAny: false, currentUser: userContext)
                ).encodeResponse(for: req)
            }
            setups = try await APITestSetup.query(on: req.db)
                .filter(\.$id ~~ visibleSetupIDs)
                .sort(\.$createdAt, .descending)
                .all()
        }

        let gradeData = try await Self.loadStudentDashboardGradeData(
            req: req, user: user, setups: setups, fmt: fmt)

        let sortedSetups = setups.sorted { lhs, rhs in
            let lhsID = lhs.id ?? ""
            let rhsID = rhs.id ?? ""
            return assignmentDisplayOrderPrecedes(
                lhsSortOrder: assignmentBySetup[lhsID]?.sortOrder,
                rhsSortOrder: assignmentBySetup[rhsID]?.sortOrder,
                lhsCreatedAt: lhs.createdAt, rhsCreatedAt: rhs.createdAt,
                lhsSetupID: lhsID, rhsSetupID: rhsID)
        }

        // Notebook presence drives the Edit button.  The zip-derived answer
        // costs an `unzip` subprocess per setup, so it is resolved through
        // ZipEntryListCache (keyed by zip mtime + size) instead of being
        // recomputed on every dashboard view.
        var hasNotebookBySetupID: [String: Bool] = [:]
        for setup in sortedSetups {
            let setupID = setup.id ?? ""
            if let path = setup.notebookPath, !path.isEmpty,
                FileManager.default.fileExists(atPath: path)
            {
                hasNotebookBySetupID[setupID] = true
            } else {
                hasNotebookBySetupID[setupID] = await req.application.zipEntryListCache
                    .zipContainsNotebook(zipPath: setup.zipPath)
            }
        }

        let rowContext = IndexRowContext(
            fmt: fmt,
            assignmentBySetup: assignmentBySetup,
            gradeData: gradeData,
            extensionDueAtBySetupID: extensionDueAtBySetupID,
            previouslyOpenedSetupIDs: previouslyOpenedSetupIDs,
            isActiveCourseStaff: isActiveCourseStaff,
            activeCourseCode: courseState.active?.code,
            hasNotebookBySetupID: hasNotebookBySetupID
        )
        let rows = sortedSetups.map { Self.buildTestSetupRow(setup: $0, context: rowContext) }

        // Sections for the active course (fetch started up top) enable the
        // grouped display below.
        let allSections = try await sectionsFetch

        // Build lookup: testSetupID → section UUID
        let sectionBySetupID: [String: UUID] = Dictionary(
            allAssignments.compactMap { a -> (String, UUID)? in
                guard let sid = a.sectionID else { return nil }
                return (a.testSetupID, sid)
            },
            uniquingKeysWith: { first, _ in first }
        )

        // Ordered display groups (shared fold, #1118): named sections with
        // visible items first, then a trailing unnamed bucket for ungrouped.
        let grouped = groupRowsBySection(
            rows: rows, sections: allSections, includeEmptySections: false,
            sectionIDForRow: { sectionBySetupID[$0.id] },
            makeSection: { section, sectionRows in
                IndexDisplayGroup(name: section.name, setups: sectionRows)
            })
        var displayGroups = grouped.sections
        if !grouped.ungrouped.isEmpty {
            displayGroups.append(IndexDisplayGroup(name: nil, setups: grouped.ungrouped))
        }

        return try await req.view.render(
            "index",
            IndexContext(
                displayGroups: displayGroups,
                hasAny: !displayGroups.isEmpty,
                currentUser: userContext
            )
        ).encodeResponse(for: req)
    }

    // The legacy GET/POST /testsetups/new raw-zip upload pair was deleted in
    // #1119: nothing had linked to it since the draft-based new-assignment
    // flow shipped, and it had drifted behind its API twin's hardening
    // (zip-bomb guard, dependency-graph validation, grading-mode checks).
    // Programmatic uploads go through POST /api/v1/testsetups.
}
