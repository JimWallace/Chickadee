// APIServer/Routes/Web/InstructorDashboardRoutes.swift
//
// Instructor-facing assignment management routes.
// Requires instructor or admin role (enforced by routes.swift).
//
//   GET  /instructor                               → assignments.leaf (all setups + status)
//   GET  /instructor/new                           → assignment-new.leaf
//   POST /instructor/new/save                      → save draft assignment, redirect to /instructor
//   POST /instructor                               → create draft assignment → redirect to edit
//   GET  /instructor/:assignmentID/edit            → assignment-edit.leaf
//   POST /instructor/:assignmentID/edit/save       → update assignment content + validate
//   POST /instructor/:assignmentID/status          → set open/closed status → redirect to /instructor
//   POST /instructor/:assignmentID/open            → set isOpen=true → redirect to /instructor
//   POST /instructor/:assignmentID/close           → set isOpen=false → redirect to /instructor
//   POST /instructor/:assignmentID/delete          → remove assignment record → redirect to /instructor
//   POST /instructor/setup/:setupID/delete         → remove orphaned (unpublished) test setup → redirect to /instructor
//
// Section CRUD + roster (enroll-csv, enrollment-mode, unenroll) live on
// `CourseAdminRoutes` as of v0.4.177.

import Core
import Fluent
import Foundation
import Vapor

struct InstructorDashboardRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // Course-scoped admin actions (enrollment mode, CSV bulk enroll,
        // unenroll, pre-enroll cancel) and section CRUD live on
        // `CourseAdminRoutes`.  Registered separately in `routes.swift`.

        // Per-course, per-student grouped submissions view + drilldown
        // live on `StudentCourseRoutes` (registered in routes.swift).

        let r = routes.grouped("instructor")
        r.get(use: list)
        // JSON sparkline series for the dashboard diagnostic cards.
        r.get("metrics", "cards", use: metricsCards)
        // Students roster tab + its self-updating poll endpoint.
        r.get("activity", use: activityPage)
        r.get("students", use: studentsPage)
        r.get("students-data", use: studentsData)
        // Reconcile the roster against the LEARN classlist (flags dropped students).
        r.get("students", "learn-check", use: studentsLearnCheck)
        // BrightSpace tab: status, grade-item mapping, sync log, manual actions.
        r.get("brightspace", use: brightspacePage)
        r.post("brightspace", "test", use: brightspaceTestConnection)
        // Per-instructor identity: connect your own LEARN account, designate it
        // as this course's sync identity, or disconnect.
        r.post("brightspace", "connect", use: brightspaceConnectAccount)
        r.post("brightspace", "use-my-identity", use: brightspaceUseMyIdentity)
        r.post("brightspace", "disconnect", use: brightspaceDisconnectAccount)
        r.post("brightspace", "bind-org-unit", use: brightspaceBindOrgUnit)
        r.get("brightspace", "grade-objects", use: brightspaceGradeObjects)
        r.post("brightspace", "auto-map", use: brightspaceAutoMap)
        r.post("brightspace", "sync-now", use: brightspaceSyncNow)
        r.post("brightspace", "reconcile-now", use: brightspaceReconcileNow)
        // MCP tab: the active course's authoring guidance for connected agents.
        r.get("mcp", use: mcpPanelPage)
        r.post("mcp", use: saveMCPGuidance)
        // Slip days tab (#1228): course policy, roster ledger, adjustments,
        // refunds.
        r.get("slip-days", use: slipDaysPage)
        r.post("slip-days", "settings", use: saveSlipDaySettings)
        r.post("slip-days", "adjust", use: adjustSlipDayBudget)
        r.post("slip-days", "refund", use: refundSlipDaySpendAction)
        r.get("grades.csv", use: exportGradesCSV)
        r.get(":assignmentID", "submissions", use: assignmentSubmissionsPage)
        r.get(":assignmentID", "students", ":studentID", "history", use: studentSubmissionHistoryPage)
        r.post(":assignmentID", "submissions", ":submissionID", "retest", use: retestSubmission)
        r.post(":assignmentID", "retest", use: retestAllSubmissions)
        r.post(":assignmentID", "students", ":studentID", "reset-notebook", use: resetStudentNotebook)
        r.post(":assignmentID", "students", ":studentID", "grade-override", use: saveStudentGradeOverride)
        r.post(
            ":assignmentID", "students", ":studentID", "grade-override", "delete",
            use: deleteStudentGradeOverride)
        r.post(
            ":assignmentID", "students", ":studentID", "regrant-reveal-token",
            use: regrantSecretRevealToken)
        // Draft-assignment authoring (create page, save, publish, draft
        // suite / family / check / script / suite-section CRUD) lives on
        // `DraftAssignmentRoutes` (registered in routes.swift).
        r.post("reorder", use: reorderAssignments)
        // Unified interleave: assignments + content items share one drag-orderable
        // per-section sequence.
        r.post("section-items", "reorder", use: reorderSectionItems)
        // Section CRUD + `:assignmentID/section` move live on
        // `CourseAdminRoutes` (registered in routes.swift).
        r.get(":assignmentID", "edit", use: editPage)
        r.post(":assignmentID", "brightspace", use: saveBrightSpaceGradeObjectID)
        r.post(":assignmentID", "secret-reveal", use: saveSecretRevealSetting)
        r.post(":assignmentID", "brightspace", "push-all", use: brightspacePushAllForAssignment)
        r.post(":assignmentID", "status", use: updateStatus)
        r.post(":assignmentID", "open", use: openAssignment)
        r.post(":assignmentID", "close", use: closeAssignment)
        r.post(":assignmentID", "delete", use: deleteAssignment)
        r.post(":assignmentID", "clone", use: cloneAssignment)
        r.post("setup", ":setupID", "delete", use: deleteUnpublishedSetup)

        // Published-assignment editor surface (edit/save, file downloads,
        // script CRUD, suite + sections + global variables + pattern
        // families + notebook checks) lives on `PublishedAssignmentRoutes`
        // (registered in routes.swift).
    }

    // MARK: - GET /instructor

    @Sendable
    func list(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)

        // Resolve active course for tab strip and scoped queries.
        let courseState = try await req.resolveActiveCourse(for: user)
        let userContext = CurrentUserContext(
            user: user,
            activeCourse: courseState.active,
            enrolledCourses: courseState.all
        )

        // If multiple courses exist but user has no enrollments → redirect to /enroll.
        if courseState.active == nil {
            let courseCount = try await APICourse.query(on: req.db).count()
            if courseCount > 0 {
                return req.redirect(to: "/enroll")
            }
        }

        let allSetups = try await loadCourseSetups(req: req, activeCourseUUID: courseState.activeCourseUUID)
        let allAssignments = try await loadCourseAssignments(req: req, activeCourseUUID: courseState.activeCourseUUID)
        let assignmentBySetup = Dictionary(
            allAssignments.map { ($0.testSetupID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let fmt = waterlooDateTimeFormatter()
        let isoFormatter = ISO8601DateFormatter()
        let allSetupIDs = allSetups.compactMap { $0.id }
        let setupIndexByID: [String: Int] = Dictionary(
            uniqueKeysWithValues: allSetups.enumerated().map { ($0.element.id ?? "", $0.offset) }
        )

        let roster: CourseRosterData
        if let activeCourseUUID = courseState.activeCourseUUID {
            roster = try await buildCourseRoster(
                req: req,
                activeCourseUUID: activeCourseUUID,
                activeCourseCode: courseState.active?.code ?? "",
                fmt: fmt,
                isoFormatter: isoFormatter
            )
        } else {
            roster = CourseRosterData(
                enrolledStudents: [],
                enrolledStudentIDs: [],
                enrolledStudentCount: 0
            )
        }

        let uniqueSubmittersBySetup = try await loadUniqueSubmittersBySetup(
            req: req,
            allSetupIDs: allSetupIDs,
            enrolledStudentIDs: roster.enrolledStudentIDs
        )

        let unsortedRows = buildAssignmentRows(
            allSetups: allSetups,
            assignmentBySetup: assignmentBySetup,
            uniqueSubmittersBySetup: uniqueSubmittersBySetup,
            activeCourse: courseState.active,
            fmt: fmt
        )
        let allSections = try await loadCourseSections(req: req, activeCourseUUID: courseState.activeCourseUUID)
        let allContentItems = try await loadCourseContentItems(
            req: req, activeCourseUUID: courseState.activeCourseUUID)
        let setupByID: [String: APITestSetup] = Dictionary(
            uniqueKeysWithValues: allSetups.compactMap { setup in setup.id.map { ($0, setup) } })
        let sectionByPublicID: [String: UUID] = Dictionary(
            allAssignments.compactMap { a -> (String, UUID)? in
                guard let sid = a.sectionID else { return nil }
                return (a.publicID, sid)
            },
            uniquingKeysWith: { first, _ in first }
        )
        // Merge each section's assignment + content lanes into one interleaved,
        // drag-orderable item list (unpublished drafts trail the ungrouped bucket).
        let (sectionContexts, ungroupedItems) = buildInstructorSectionItems(
            assignmentRows: unsortedRows,
            contentItems: allContentItems,
            allSections: allSections,
            sectionByPublicID: sectionByPublicID,
            setupByID: setupByID,
            setupIndexByID: setupIndexByID
        )

        let hasSections = !allSections.isEmpty
        let hasUngrouped = !ungroupedItems.isEmpty
        let ctx = AssignmentsContext(
            currentUser: userContext,
            activeInstructorTab: "overview",
            sections: sectionContexts,
            ungroupedItems: ungroupedItems,
            hasSections: hasSections,
            showUngroupedBlock: hasUngrouped || !hasSections,
            showEmptyMessage: !hasSections && !hasUngrouped,
            enrolledStudentCount: roster.enrolledStudentCount
        )
        return try await req.view.render("assignments", ctx).encodeResponse(for: req)
    }

    // MARK: - POST /instructor/:assignmentID/open

    @Sendable
    func openAssignment(req: Request) async throws -> Response {
        let assignment = try await loadAssignmentForWrite(req, atLeast: .instructor)
        do {
            try await AssignmentAuthoringService.setOpenState(assignment, open: true, on: req.db)
        } catch AssignmentAuthoringError.validationNotPassed {
            throw WebAssignmentError.validationRequired(
                reason: "Assignment cannot be opened until runner validation passes."
            )
        }
        return req.redirect(to: "/instructor")
    }

    // MARK: - POST /instructor/reorder

    @Sendable
    func reorderAssignments(req: Request) async throws -> HTTPStatus {
        struct ReorderBody: Content {
            var assignmentIDs: [String]
        }
        let caller = try req.auth.require(APIUser.self)
        let body = try req.content.decode(ReorderBody.self)
        let orderedIDs = Array(NSOrderedSet(array: body.assignmentIDs).compactMap { $0 as? String })
        guard !orderedIDs.isEmpty else { return .ok }
        guard orderedIDs.allSatisfy(isValidAssignmentPublicID(_:)) else {
            throw WebAssignmentError.invalidParameter(
                name: "assignmentIDs",
                reason: "invalid assignment ID in reorder payload"
            )
        }

        let assignments = try await APIAssignment.query(on: req.db)
            .filter(\.$publicID ~~ orderedIDs)
            .all()
        let byID = Dictionary(uniqueKeysWithValues: assignments.map { ($0.publicID, $0) })
        guard byID.count == orderedIDs.count else {
            throw WebAssignmentError.invalidParameter(
                name: "assignmentIDs",
                reason: "assignment set mismatch in reorder payload"
            )
        }

        // Reordering writes sortOrder, so it's a per-course write: authorize the
        // caller for every distinct course the payload touches. Without this an
        // instructor could reorder another course's (or an archived course's)
        // assignments by submitting their IDs — the active-course group gate
        // never sees the target courses here (#417 Slice D).
        for courseID in Set(assignments.map(\.courseID)) {
            try await requireCourseWriteAccess(caller: caller, courseID: courseID, atLeast: .instructor, db: req.db)
        }

        for (index, rawID) in orderedIDs.enumerated() {
            guard let assignment = byID[rawID] else { continue }
            assignment.sortOrder = index + 1
            try await assignment.save(on: req.db)
        }
        return .ok
    }

    // MARK: - POST /instructor/section-items/reorder

    /// Persists the interleaved order of a section's items — assignments AND
    /// content items share one per-section `sort_order` sequence, so this
    /// renumbers both tables `1..n` in the given mixed order. `items` is the
    /// section's full ordered list; each entry names its `type`
    /// ("assignment" | "content") and `id`. Every touched course is authorized
    /// (TA+, matching content authoring). AJAX (returns `.ok`).
    @Sendable
    func reorderSectionItems(req: Request) async throws -> HTTPStatus {
        struct ItemRef: Content {
            var type: String
            var id: String
        }
        struct ReorderBody: Content {
            /// The lane the client reordered; informational — the item set below
            /// defines exactly which rows are renumbered.
            var sectionID: String?
            var items: [ItemRef]
        }
        let caller = try req.auth.require(APIUser.self)
        let body = try req.content.decode(ReorderBody.self)
        guard !body.items.isEmpty else { return .ok }

        let assignmentIDs = body.items.filter { $0.type == "assignment" }.map(\.id)
        let contentUUIDs = body.items.filter { $0.type == "content" }.compactMap { UUID(uuidString: $0.id) }
        guard assignmentIDs.allSatisfy(isValidAssignmentPublicID(_:)) else {
            throw WebAssignmentError.invalidParameter(
                name: "items", reason: "invalid assignment ID in reorder payload")
        }
        guard
            contentUUIDs.count == body.items.filter({ $0.type == "content" }).count
        else {
            throw WebAssignmentError.invalidParameter(
                name: "items", reason: "invalid content-item ID in reorder payload")
        }

        let assignments =
            assignmentIDs.isEmpty
            ? []
            : try await APIAssignment.query(on: req.db).filter(\.$publicID ~~ assignmentIDs).all()
        let contentItems =
            contentUUIDs.isEmpty
            ? []
            : try await APICourseContentItem.query(on: req.db).filter(\.$id ~~ contentUUIDs).all()
        guard assignments.count == Set(assignmentIDs).count,
            contentItems.count == Set(contentUUIDs).count
        else {
            throw WebAssignmentError.invalidParameter(
                name: "items", reason: "item set mismatch in reorder payload")
        }
        let assignmentByPublicID = Dictionary(uniqueKeysWithValues: assignments.map { ($0.publicID, $0) })
        let contentByID = Dictionary(
            uniqueKeysWithValues: contentItems.compactMap { c in c.id.map { ($0, c) } })

        // Reordering writes sort_order across every course the payload touches:
        // authorize each so the payload can't renumber another (or archived)
        // course's items (#417 Slice D). TA+, matching content authoring.
        var courses = Set(assignments.map(\.courseID))
        courses.formUnion(contentItems.map(\.courseID))
        for courseID in courses {
            try await requireCourseWriteAccess(caller: caller, courseID: courseID, atLeast: .ta, db: req.db)
        }

        for (index, ref) in body.items.enumerated() {
            let order = index + 1
            if ref.type == "assignment", let assignment = assignmentByPublicID[ref.id] {
                assignment.sortOrder = order
                try await assignment.save(on: req.db)
            } else if ref.type == "content", let uuid = UUID(uuidString: ref.id),
                let item = contentByID[uuid]
            {
                item.sortOrder = order
                try await item.save(on: req.db)
            }
        }
        return .ok
    }

    // MARK: - POST /instructor/:assignmentID/status

    @Sendable
    func updateStatus(req: Request) async throws -> Response {
        struct StatusBody: Content {
            var status: String
        }

        let assignment = try await loadAssignmentForWrite(req, atLeast: .instructor)

        let body = try req.content.decode(StatusBody.self)
        guard let visibility = AssignmentVisibility(rawValue: body.status) else {
            throw WebAssignmentError.invalidParameter(
                name: "status",
                reason: "unsupported status '\(body.status)'"
            )
        }
        do {
            try await AssignmentAuthoringService.setVisibility(assignment, visibility, on: req.db)
        } catch AssignmentAuthoringError.validationNotPassed {
            throw WebAssignmentError.validationRequired(
                reason: "Assignment cannot be opened until runner validation passes."
            )
        }
        await AuditLogger.recordAssignmentLifecycle(
            .assignmentVisibilityChanged, assignment: assignment,
            metadata: ["visibility": visibility.rawValue], on: req)
        return req.redirect(to: "/instructor")
    }

    // MARK: - POST /instructor/:assignmentID/close

    @Sendable
    func closeAssignment(req: Request) async throws -> Response {
        let assignment = try await loadAssignmentForWrite(req, atLeast: .instructor)
        try await AssignmentAuthoringService.setOpenState(assignment, open: false, on: req.db)
        await AuditLogger.recordAssignmentLifecycle(
            .assignmentVisibilityChanged, assignment: assignment,
            metadata: ["visibility": AssignmentVisibility.closed.rawValue], on: req)
        return req.redirect(to: "/instructor")
    }

    // MARK: - POST /instructor/:assignmentID/clone

    /// Duplicates an assignment (notebooks, suite zip, manifest) into a new
    /// closed/unvalidated copy in the same course — the web counterpart of the
    /// `clone_assignment` MCP tool, both going through
    /// `AssignmentAuthoringService.cloneAssignment` so they can't drift. Lands
    /// the instructor on the new copy's edit page to set a due date and
    /// re-validate before opening.
    @Sendable
    func cloneAssignment(req: Request) async throws -> Response {
        // Write-scoped to the source's own course: cloning creates a new
        // assignment in that course, so a clone of an archived course's
        // assignment is a write to an archived course and is blocked for
        // non-admins (#417, follow-up to Slice A — "clone reads from a
        // possibly-archived source").
        // Cloning creates a *new* assignment (course structure), so it's
        // instructor-only — unlike the content edits this loader defaults to .ta.
        let (source, sourceSetup) = try await loadAssignmentAndSetupForWrite(req, atLeast: .instructor)
        let cloned = try await AssignmentAuthoringService.cloneAssignment(
            source: source,
            sourceSetup: sourceSetup,
            newTitle: "\(source.title) (Copy)",
            targetCourseID: source.courseID,
            setupsDirectory: req.application.testSetupsDirectory,
            on: req.db)
        await AuditLogger.recordAssignmentLifecycle(
            .assignmentCloned, assignment: cloned.assignment,
            metadata: ["source_assignment": source.publicID, "title": cloned.assignment.title],
            on: req)
        let notice = "Cloned from \(source.title). Set a due date and re-validate, then open."
        return req.redirect(to: "/instructor/\(cloned.assignment.publicID)/edit?notice=\(urlEncode(notice))")
    }

    // MARK: - POST /instructor/:assignmentID/brightspace

    @Sendable
    func saveBrightSpaceGradeObjectID(req: Request) async throws -> Response {
        let assignment = try await loadAssignmentForWrite(req, atLeast: .instructor)
        struct BSBody: Content {
            var gradeObjectID: String?
            /// "brightspace" → return to the BrightSpace tab (mapping table);
            /// otherwise the assignment edit page (the legacy caller).
            var returnTo: String?
        }
        let body = try req.content.decode(BSBody.self)
        let raw = (body.gradeObjectID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let mapping: String
        if raw == BrightspaceSync.doNotSyncToken {
            // The instructor picked the "Do not sync" option in the grade-item
            // dropdown — exclude this assignment from LEARN. The sweep then skips
            // it; the dropdown shows "Do not sync" until a real item is chosen.
            assignment.brightspaceSyncExcluded = true
            assignment.brightspaceGradeObjectID = nil
            mapping = "do_not_sync"
        } else {
            assignment.brightspaceSyncExcluded = false
            assignment.brightspaceGradeObjectID = raw.isEmpty ? nil : raw
            mapping = raw.isEmpty ? "cleared" : raw
        }
        try await assignment.save(on: req.db)
        await AuditLogger.record(
            action: .brightspaceGradeItemMapped,
            targetType: .assignment,
            targetID: assignment.id?.uuidString,
            metadata: ["assignment": assignment.publicID, "grade_item": mapping],
            on: req
        )
        if body.returnTo == "brightspace" {
            return req.redirect(to: "/instructor/brightspace")
        }
        return req.redirect(to: "/instructor/\(assignment.publicID)/edit?notice=BrightSpace+grade+item+ID+saved")
    }

    // MARK: - POST /instructor/:assignmentID/secret-reveal

    /// Saves the per-assignment secret-reveal toggle. A dedicated lightweight
    /// endpoint rather than a field on the main Save form: `saveEditedAssignment`
    /// closes the assignment and re-enqueues validation on every save, which
    /// would make a mid-semester toggle flip needlessly destructive. Display
    /// policy only — no manifest change, no regrade, no close.
    @Sendable
    func saveSecretRevealSetting(req: Request) async throws -> Response {
        let assignment = try await loadAssignmentForWrite(req, atLeast: .instructor)
        struct ToggleBody: Content {
            // Checkbox: "on" when checked, absent from the body when not —
            // decode as optional and treat absence as false, so unchecking
            // actually turns the toggle off.
            var enabled: String?
        }
        let enabled = ((try? req.content.decode(ToggleBody.self))?.enabled) != nil
        try await AssignmentAuthoringService.updateMetadata(
            assignment, secretRevealEnabled: enabled, on: req.db)
        await AuditLogger.record(
            action: .secretRevealToggled,
            targetType: .assignment,
            targetID: assignment.id?.uuidString,
            metadata: ["assignment": assignment.publicID, "enabled": String(enabled)],
            on: req
        )
        return req.redirect(
            to: "/instructor/\(assignment.publicID)/edit?notice=Secret+reveal+token+setting+saved")
    }

    // MARK: - POST /instructor/:assignmentID/delete

    @Sendable
    func deleteAssignment(req: Request) async throws -> Response {
        let assignment = try await loadAssignmentForWrite(req, atLeast: .instructor)
        let setupID = assignment.testSetupID

        // Delete related submissions and their result rows for this setup.
        let submissions = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == setupID)
            .all()
        let submissionIDs = submissions.compactMap(\.id)
        if !submissionIDs.isEmpty {
            try await APIResult.query(on: req.db)
                .filter(\.$submissionID ~~ submissionIDs)
                .delete()
            try await APISubmission.query(on: req.db)
                .filter(\.$id ~~ submissionIDs)
                .delete()
        }

        // Delete setup artifacts and setup row so it disappears from the assignments list.
        if let setup = try await APITestSetup.find(setupID, on: req.db) {
            try? FileManager.default.removeItem(atPath: setup.zipPath)
            if let notebookPath = setup.notebookPath, !notebookPath.isEmpty {
                try? FileManager.default.removeItem(atPath: notebookPath)
            }
            removeMaterializedNotebookFiles(req: req, setupID: setupID)
            try await setup.delete(on: req.db)
        }

        // Recorded BEFORE the row goes: after the delete there is no assignment
        // to attribute the event to, and no version row survives either — this
        // is the only trace that the assignment ever existed.
        await AuditLogger.recordAssignmentLifecycle(
            .assignmentDeleted, assignment: assignment,
            metadata: [
                "title": assignment.title,
                "submissions_deleted": String(submissionIDs.count),
            ], on: req)
        try await assignment.delete(on: req.db)
        return req.redirect(to: "/instructor")
    }

    // MARK: - POST /instructor/setup/:setupID/delete

    @Sendable
    func deleteUnpublishedSetup(req: Request) async throws -> Response {
        let caller = try req.auth.require(APIUser.self)
        let setupID = req.parameters.get("setupID") ?? ""
        guard let setup = try await APITestSetup.find(setupID, on: req.db) else {
            throw WebAssignmentError.notFound(resource: "Test setup '\(setupID)'")
        }
        // Scope the delete to the setup's own course (the :setupID param-taking
        // route is otherwise drivable cross-course / against an archived course;
        // the active-course group gate can't see the setup's course) (#417 Slice D).
        try await requireCourseWriteAccess(caller: caller, courseID: setup.courseID, atLeast: .instructor, db: req.db)
        // Only allow deleting setups that have no associated assignment.
        let hasAssignment =
            try await APIAssignment.query(on: req.db)
            .filter(\.$testSetupID == setupID)
            .count() > 0
        guard !hasAssignment else {
            throw WebAssignmentError.conflict(
                reason: "Test setup '\(setupID)' has a published assignment and cannot be deleted from this endpoint."
            )
        }

        try? FileManager.default.removeItem(atPath: setup.zipPath)
        if let notebookPath = setup.notebookPath, !notebookPath.isEmpty {
            try? FileManager.default.removeItem(atPath: notebookPath)
        }
        removeMaterializedNotebookFiles(req: req, setupID: setupID)
        try await setup.delete(on: req.db)
        return req.redirect(to: "/instructor")
    }

    // MARK: - GET /instructor/:assignmentID/edit

    @Sendable
    func editPage(req: Request) async throws -> View {
        let ctx = try await makeEditAssignmentContext(req: req, embedded: false)
        return try await req.view.render("assignment-edit", ctx)
    }

    /// Builds the edit page's context.
    ///
    /// Factored out of `editPage` so the assignment workbench's left pane
    /// (`GET /instructor/:assignmentID/workbench`,
    /// `InstructorWorkbenchRoutes`) renders the *same* page from the *same*
    /// 26-field construction rather than a copy of it that would drift.  The
    /// only difference between the two callers is `embedded`, which suppresses
    /// the site chrome — the staff gate, the query overrides, and every
    /// derived field are identical.
    func makeEditAssignmentContext(
        req: Request,
        embedded: Bool
    ) async throws -> EditAssignmentContext {
        let (assignment, setup) = try await loadAssignmentAndSetupForStaffRead(req)
        let idStr = assignment.publicID

        struct EditQuery: Content {
            var assignmentName: String?
            var dueAt: String?
            var startsAt: String?
            var error: String?
            var notice: String?
        }
        let q = try? req.query.decode(EditQuery.self)
        let draftSolutionPath = draftSolutionNotebookPath(
            testSetupsDirectory: req.application.testSetupsDirectory, setupID: assignment.testSetupID)
        let existingSolutionName = try await existingSolutionFilename(req: req, assignment: assignment)
        let hasDraftSolution = FileManager.default.fileExists(atPath: draftSolutionPath)
        let fallbackSolutionFilename =
            (assignment.validationStatus == "passed"
                || assignment.validationSubmissionID != nil
                || hasDraftSolution) ? "solution.ipynb" : nil
        let currentFiles = currentSetupFiles(
            for: setup,
            assignmentID: idStr,
            solutionFilename: existingSolutionName ?? fallbackSolutionFilename
        )
        let currentDueAt = dueAtLocalInputString(assignment.dueAt)
        let currentStartsAt = dueAtLocalInputString(assignment.startsAt)
        let manifest = setup.decodedManifest()
        let patternFamiliesJSON: String = {
            guard let props = manifest else { return "[]" }
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            let familyData = (try? enc.encode(props.patternFamilies)) ?? Data("[]".utf8)
            return String(data: familyData, encoding: .utf8) ?? "[]"
        }()
        let notebookChecksJSON: String = {
            guard let props = manifest else { return "[]" }
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            let checkData = (try? enc.encode(props.notebookChecks)) ?? Data("[]".utf8)
            return String(data: checkData, encoding: .utf8) ?? "[]"
        }()
        return EditAssignmentContext(
            currentUser: req.currentUserContext,
            assignmentID: idStr,
            testSetupID: assignment.testSetupID,
            assignmentName: (q?.assignmentName ?? assignment.title).trimmingCharacters(in: .whitespacesAndNewlines),
            dueAt: q?.dueAt ?? currentDueAt,
            startsAt: q?.startsAt ?? currentStartsAt,
            currentAssignmentFile: currentFiles.assignmentFile.name,
            currentAssignmentURL: currentFiles.assignmentFile.url,
            assignmentNotebookEditURL:
                "/testsetups/\(assignment.testSetupID)/notebook?title=\(urlEncode(assignment.title))",
            currentSolutionFile: currentFiles.solutionFile?.name,
            currentSolutionURL: currentFiles.solutionFile?.url,
            solutionNotebookEditURL: currentFiles.solutionFile != nil
                ? "/testsetups/\(assignment.testSetupID)/notebook?file=solution&title=\(urlEncode("Solution Notebook"))"
                : nil,
            existingSuiteRows: currentFiles.existingSuiteRows.filter { $0.tier != "support" },
            supportFileRows: currentFiles.existingSuiteRows.filter { $0.tier == "support" },
            familyRows: familySuiteRowsForSetup(setup),
            patternFamiliesJSON: patternFamiliesJSON,
            notebookChecksJSON: notebookChecksJSON,
            checkSchemaJSON: notebookCheckFormSchemaJSON(),
            suiteStateJSON: suiteStateJSON(fromManifest: setup.manifest, zipPath: setup.zipPath),
            suiteSectionRows: suiteSectionShellRows(fromManifest: setup.manifest),
            globalVariableRows: globalVariableShellRows(fromManifest: setup.manifest),
            achievementSignalOptions: AchievementSignalPresentation.all,
            brightspaceSyncEnabled: req.application.brightSpaceAppCredentials != nil,
            brightspaceGradeObjectID: assignment.brightspaceGradeObjectID,
            secretRevealEnabled: assignment.secretRevealEnabled == true,
            timeLimitSeconds: manifest?.timeLimitSeconds ?? 10,
            notice: q?.notice,
            error: q?.error,
            // nil rather than `false` on the standalone page so its rendered
            // HTML is byte-identical to before the workbench existed.
            embedded: embedded ? true : nil,
            // Where a write inside the pane sends the pane afterwards.  Must
            // match the route `InstructorWorkbenchRoutes` registers, since the
            // pane is already showing it.
        )
    }
}
