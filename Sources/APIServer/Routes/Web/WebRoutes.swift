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
        routes.post("testsetups", ":testSetupID", "reveal-secret", use: spendSecretRevealToken)
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

        // Lazy safety net for scheduled opens, mirroring the lazy deadline
        // close in requireOpenStudentAssignment: if the periodic sweep missed
        // an assignment whose open date has arrived, the very dashboard load
        // that would otherwise show it stuck (a TA checking why the lab isn't
        // up, a student looking for it) repairs the state instead of just
        // observing it. Row-wise on the already-loaded list; every guard
        // short-circuits in memory, so this writes nothing unless a scheduled
        // open is actually due.
        for assignment in allAssignments {
            _ = try? await openScheduledAssignment(assignment, on: req.db, logger: req.logger)
        }
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
        // Ungraded content items grouped alongside assignments. Staff see
        // drafts; students see only published items.
        async let contentItemsFetch = Self.loadCourseContentItems(
            activeCourseUUID: courseState.activeCourseUUID,
            includeUnpublished: isActiveCourseStaff, db: req.db)

        let extensionDueAtBySetupID = try await extensionsFetch
        let previouslyOpenedSetupIDs = try await previouslyOpenedFetch

        // Staff see every setup in the course; students see the published /
        // extension-revealed / previously-engaged set (loader owns the rules).
        // An empty list falls through to the same empty-dashboard render the
        // grouping below produces naturally.
        let setups = try await Self.loadDashboardSetups(
            activeCourseUUID: activeCourseUUID,
            isActiveCourseStaff: isActiveCourseStaff,
            allAssignments: allAssignments,
            extensionDueAtBySetupID: extensionDueAtBySetupID,
            previouslyOpenedSetupIDs: previouslyOpenedSetupIDs,
            db: req.db)

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

        let hasNotebookBySetupID = await Self.loadHasNotebookBySetupID(
            setups: sortedSetups, application: req.application)

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

        // Bucket both lanes — graded assignment rows and ungraded content items
        // — by section, then assemble the ordered display groups. Done inline
        // (rather than via the shared `groupRowsBySection` fold) because a group
        // now carries two row types and a section with content items but no
        // visible assignments must still render — the fold's
        // `includeEmptySections: false` would drop it.
        var setupRowsBySectionID: [UUID: [TestSetupRow]] = [:]
        var ungroupedSetupRows: [TestSetupRow] = []
        for row in rows {
            if let sid = sectionBySetupID[row.id] {
                setupRowsBySectionID[sid, default: []].append(row)
            } else {
                ungroupedSetupRows.append(row)
            }
        }
        let contentItems = try await contentItemsFetch
        var contentRowsBySectionID: [UUID: [ContentItemRow]] = [:]
        var ungroupedContentRows: [ContentItemRow] = []
        for item in contentItems {
            let contentRow = ContentItemRow(from: item)
            if let sid = item.sectionID {
                contentRowsBySectionID[sid, default: []].append(contentRow)
            } else {
                ungroupedContentRows.append(contentRow)
            }
        }
        var displayGroups: [IndexDisplayGroup] = []
        for section in allSections {
            guard let sid = section.id else { continue }
            let sectionSetups = setupRowsBySectionID[sid] ?? []
            let sectionContent = contentRowsBySectionID[sid] ?? []
            // Drop only sections with nothing to show in either lane.
            if sectionSetups.isEmpty, sectionContent.isEmpty { continue }
            displayGroups.append(
                IndexDisplayGroup(
                    name: section.name, contentItems: sectionContent, setups: sectionSetups))
        }
        if !ungroupedSetupRows.isEmpty || !ungroupedContentRows.isEmpty {
            displayGroups.append(
                IndexDisplayGroup(
                    name: nil, contentItems: ungroupedContentRows, setups: ungroupedSetupRows))
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
