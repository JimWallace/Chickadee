// APIServer/Routes/Web/AssignmentRoutes.swift
//
// Instructor-facing assignment management routes.
// Requires instructor or admin role (enforced by routes.swift).
//
//   GET  /instructor                               → assignments.leaf (all setups + status)
//   GET  /instructor/new                           → assignment-new.leaf
//   POST /instructor/new/save                      → save draft assignment, redirect to /instructor
//   POST /instructor                               → create draft assignment → redirect to validate
//   GET  /instructor/:assignmentID/validate        → assignment-validate.leaf
//   GET  /instructor/:assignmentID/edit            → assignment-edit.leaf
//   POST /instructor/:assignmentID/edit/save       → update assignment content + validate
//   POST /instructor/:assignmentID/status          → set open/closed status → redirect to /instructor
//   POST /instructor/:assignmentID/open            → set isOpen=true → redirect to /instructor
//   POST /instructor/:assignmentID/close           → set isOpen=false → redirect to /instructor
//   POST /instructor/:assignmentID/delete          → remove assignment record → redirect to /instructor
//   POST /instructor/setup/:setupID/delete         → remove orphaned (unpublished) test setup → redirect to /instructor
//   POST /instructor/:assignmentID/section         → move assignment to a section (or ungrouped)
//   POST /instructor/sections                      → create a new course section
//   POST /instructor/sections/reorder              → reorder sections
//   POST /instructor/sections/:sectionID/rename    → rename/reconfigure a section
//   POST /instructor/sections/:sectionID/delete    → delete a section

import Core
import Fluent
import Foundation
import Vapor

struct AssignmentRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // Course-scoped instructor actions (not under the /instructor prefix).
        routes.post("courses", ":courseID", "enrollment-mode", use: setCourseEnrollmentMode)
        routes.post("courses", ":courseID", "enroll-csv", use: instructorBulkEnrollCSV)
        routes.post("courses", ":courseID", "unenroll", ":userID", use: instructorUnenrollUser)
        routes.post("courses", ":courseID", "pre-unenroll", ":preEnrollmentID", use: instructorCancelPreEnrollment)

        let r = routes.grouped("instructor")
        r.get(use: list)
        r.get("grades.csv", use: exportGradesCSV)
        r.get("enroll-csv", use: enrollCSVForm)
        r.get("students", ":studentID", "submissions", use: courseStudentSubmissionsPage)
        r.get(":assignmentID", "submissions", use: assignmentSubmissionsPage)
        r.get(":assignmentID", "students", ":studentID", "history", use: studentSubmissionHistoryPage)
        r.post(":assignmentID", "submissions", ":submissionID", "retest", use: retestSubmission)
        r.post(":assignmentID", "retest", use: retestAllSubmissions)
        r.post(":assignmentID", "students", ":studentID", "reset-notebook", use: resetStudentNotebook)
        r.get("new", use: newAssignmentPage)
        r.post("new", "draft", use: updateNewAssignmentDraft)
        r.get("new", "draft", "solution-notebook", use: draftSolutionNotebook)
        // Draft-scoped suite / families / scripts endpoints.  Mirror the
        // `:assignmentID`-scoped routes below, but identify the target
        // `APITestSetup` via a `draftID` query parameter because the
        // assignment hasn't been published yet.  Added in v0.4.91 so the
        // Create Assignment page can author pattern families before save.
        r.get("new", "draft", "suite", use: getDraftSuite)
        r.put("new", "draft", "suite", use: putDraftSuite)
        r.put("new", "draft", "families", use: putDraftPatternFamilies)
        // Draft-scoped notebook checks (v0.4.132 / parity PR 2 of #433).
        // Mirrors PUT /instructor/:assignmentID/checks; uses the shared
        // applyNotebookChecksEdit core, which also re-applies the current
        // pattern families so both generated-script sets stay in sync.
        r.put("new", "draft", "checks", use: putDraftNotebookChecks)
        r.post("new", "draft", "scripts", use: createDraftScript)
        r.delete("new", "draft", "scripts", ":filename", use: deleteDraftScript)
        // Draft-scoped file download (v0.4.132 / parity PR 3 of #433).
        // Used by the support-file list on the create page so instructors
        // can click a filename to inspect the bundled data file before
        // publish.  Mirrors `downloadCurrentSetupItem` for the assignment-
        // scoped case.
        r.get("new", "draft", "files", "item", use: downloadDraftSetupItem)
        // Draft-scoped suite-section CRUD (v0.4.132, #435).  Mirrors the
        // assignment-scoped routes registered below; identical body /
        // validation / response shape, only the resolver and redirect
        // target differ.  See AssignmentRoutes+DraftSections.swift.
        r.post("new", "draft", "suite-sections", use: createDraftSuiteSection)
        r.post("new", "draft", "suite-sections", "reorder", use: reorderDraftSuiteSections)
        r.post("new", "draft", "suite-sections", ":sectionID", "rename", use: renameDraftSuiteSection)
        r.post("new", "draft", "suite-sections", ":sectionID", "delete", use: deleteDraftSuiteSection)
        r.post("new", "draft", "suite-sections", ":sectionID", "variables", use: updateDraftSuiteSectionVariables)
        r.post("new", "save", use: saveNewAssignment)
        r.post("reorder", use: reorderAssignments)
        r.post("sections", use: createSection)
        r.post("sections", "reorder", use: reorderSections)
        r.post("sections", ":sectionID", "rename", use: renameSection)
        r.post("sections", ":sectionID", "delete", use: deleteSection)
        r.post(":assignmentID", "section", use: moveToSection)
        r.post(use: publish)
        r.get(":assignmentID", "validate", use: validatePage)
        r.get(":assignmentID", "edit", use: editPage)
        r.post(":assignmentID", "edit", "save", use: saveEditedAssignment)
        r.get(":assignmentID", "files", "notebook", use: downloadCurrentNotebookFile)
        r.get(":assignmentID", "files", "solution", use: downloadCurrentSolutionFile)
        r.get(":assignmentID", "files", "item", use: downloadCurrentSetupItem)
        r.post(":assignmentID", "brightspace", use: saveBrightSpaceGradeObjectID)
        r.post(":assignmentID", "status", use: updateStatus)
        r.post(":assignmentID", "open", use: openAssignment)
        r.post(":assignmentID", "close", use: closeAssignment)
        r.post(":assignmentID", "delete", use: deleteAssignment)
        r.post("setup", ":setupID", "delete", use: deleteUnpublishedSetup)
        r.post(":assignmentID", "create-solution", use: createSolutionFromAssignment)

        // Script editor — inline CRUD for individual test/support files in the setup zip.
        r.get("script-templates", use: getScriptTemplates)
        r.post("scan-notebook", use: scanNotebook)
        r.get(":assignmentID", "scripts", ":filename", use: getScript)
        r.put(":assignmentID", "scripts", ":filename", use: updateScript)
        r.post(":assignmentID", "scripts", use: createScript)
        r.delete(":assignmentID", "scripts", ":filename", use: deleteScript)

        // Pattern family editor — canonical spec lives inside the test setup
        // manifest.  PUT replaces the full list atomically (renders scripts,
        // mutates the zip, rewrites the manifest); GET reads the current list.
        r.get(":assignmentID", "families", use: getPatternFamilies)
        r.put(":assignmentID", "families", use: putPatternFamilies)

        // Notebook check editor — sibling concept to pattern families.
        // Same atomic-replace semantics as /families above.  Each check
        // expands to exactly one generated test script at save time.
        r.get(":assignmentID", "checks", use: getNotebookChecks)
        r.put(":assignmentID", "checks", use: putNotebookChecks)

        // Unified suite editor — GET returns the full reconciled list
        // (scripts + families, in manifest order).  PUT replaces the whole
        // list atomically; each mutation in the suite-edit UI sends a fresh
        // snapshot here and replaces its local state from the response.
        r.get(":assignmentID", "suite", use: getSuite)
        r.put(":assignmentID", "suite", use: putSuite)

        // Suite-section CRUD — per-op, form-POST + redirect (v0.4.98).
        // Mirrors the instructor-dashboard course-section pattern
        // (`AssignmentRoutes+Sections.swift`) so section create / rename /
        // delete / reorder don't have to ride the whole-state `PUT /suite`
        // pipeline.  These handlers mutate `manifest.sections` directly —
        // they do NOT rebuild the zip or re-run `applyPatternFamilies`.
        r.post(":assignmentID", "suite-sections", use: createSuiteSection)
        r.post(":assignmentID", "suite-sections", "reorder", use: reorderSuiteSections)
        r.post(":assignmentID", "suite-sections", ":sectionID", "rename", use: renameSuiteSection)
        r.post(":assignmentID", "suite-sections", ":sectionID", "delete", use: deleteSuiteSection)
        r.post(":assignmentID", "suite-sections", ":sectionID", "variables", use: updateSuiteSectionVariables)

        // Slice 1 — assignment-scope global variables.  Same `+ Add Input`
        // shape as section vars but visible to every pattern family,
        // every raw test script, and every `{{name}}` placeholder in the
        // starter notebook.  Triggers a full `applyPatternFamilies`
        // re-render so generated tests get the new values inlined and
        // raw scripts get re-prepended (idempotent — unchanged scripts
        // stay byte-identical).
        r.get(":assignmentID", "global-variables", use: getGlobalVariables)
        r.put(":assignmentID", "global-variables", use: putGlobalVariables)
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
                allSetupIDs: allSetupIDs,
                fmt: fmt,
                isoFormatter: isoFormatter
            )
        } else {
            roster = CourseRosterData(
                enrolledStudents: [],
                enrolledStudentIDs: [],
                enrolledStudentCount: 0,
                metrics: Self.placeholderDashboardMetrics()
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
        let sortedRows = sortAssignmentRows(unsortedRows, setupIndexByID: setupIndexByID)

        let allSections = try await loadCourseSections(req: req, activeCourseUUID: courseState.activeCourseUUID)
        let sectionByPublicID: [String: UUID] = Dictionary(
            allAssignments.compactMap { a -> (String, UUID)? in
                guard let sid = a.sectionID else { return nil }
                return (a.publicID, sid)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let (sectionContexts, ungroupedRows) = groupRowsBySection(
            sortedRows: sortedRows,
            allSections: allSections,
            sectionByPublicID: sectionByPublicID
        )

        // Fetch enrollment mode and archived state for the active course.
        var courseEnrollmentMode = CourseEnrollmentMode.open.rawValue
        var courseIsArchived = false
        if let activeCourseUUID = courseState.activeCourseUUID,
            let activeCourseModel = try await APICourse.find(activeCourseUUID, on: req.db)
        {
            courseEnrollmentMode = activeCourseModel.enrollmentMode.rawValue
            courseIsArchived = activeCourseModel.isArchived
        }

        let ctx = AssignmentsContext(
            currentUser: userContext,
            metrics: roster.metrics,
            sections: sectionContexts,
            ungroupedRows: ungroupedRows,
            hasSections: !allSections.isEmpty,
            hasUngrouped: !ungroupedRows.isEmpty,
            enrolledStudents: roster.enrolledStudents,
            hasEnrolledStudents: !roster.enrolledStudents.isEmpty,
            enrolledStudentCount: roster.enrolledStudentCount,
            courseEnrollmentMode: courseEnrollmentMode,
            courseIsArchived: courseIsArchived
        )
        return try await req.view.render("assignments", ctx).encodeResponse(for: req)
    }

    // MARK: - GET /instructor/:assignmentID/validate

    @Sendable
    func validatePage(req: Request) async throws -> View {
        let idStr = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(idStr)'")
        }

        let suiteCount: Int = {
            guard let data = setup.manifest.data(using: .utf8),
                let props = try? ManifestCodec.decoder.decode(TestProperties.self, from: data)
            else { return 0 }
            return props.testSuites.count
        }()

        let fmt = waterlooDateTimeFormatter()

        let ctx = ValidateContext(
            currentUser: req.currentUserContext,
            assignmentID: idStr,
            setupID: assignment.testSetupID,
            title: assignment.title,
            suiteCount: suiteCount,
            dueAt: assignment.dueAt.map { fmt.string(from: $0) }
        )
        return try await req.view.render("assignment-validate", ctx)
    }

    // MARK: - POST /instructor/:assignmentID/open

    @Sendable
    func openAssignment(req: Request) async throws -> Response {
        let idStr = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db)
        else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(idStr)'")
        }
        guard assignment.validationStatus == nil || assignment.validationStatus == "passed" else {
            throw WebAssignmentError.validationRequired(
                reason: "Assignment cannot be opened until runner validation passes."
            )
        }
        assignment.isOpen = true
        assignment.deadlineOverrideActive = deadlineOverrideValueForInstructorOpen(dueAt: assignment.dueAt)
        try await assignment.save(on: req.db)
        return req.redirect(to: "/instructor")
    }

    // MARK: - POST /instructor/reorder

    @Sendable
    func reorderAssignments(req: Request) async throws -> HTTPStatus {
        struct ReorderBody: Content {
            var assignmentIDs: [String]
        }
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

        for (index, rawID) in orderedIDs.enumerated() {
            guard let assignment = byID[rawID] else { continue }
            assignment.sortOrder = index + 1
            try await assignment.save(on: req.db)
        }
        return .ok
    }

    // MARK: - POST /instructor/:assignmentID/status

    @Sendable
    func updateStatus(req: Request) async throws -> Response {
        struct StatusBody: Content {
            var status: String
        }

        let idStr = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db)
        else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(idStr)'")
        }

        let body = try req.content.decode(StatusBody.self)
        switch body.status {
        case "open":
            guard assignment.validationStatus == nil || assignment.validationStatus == "passed" else {
                throw WebAssignmentError.validationRequired(
                    reason: "Assignment cannot be opened until runner validation passes."
                )
            }
            assignment.isOpen = true
            assignment.deadlineOverrideActive = deadlineOverrideValueForInstructorOpen(dueAt: assignment.dueAt)
        case "closed":
            assignment.isOpen = false
        default:
            throw WebAssignmentError.invalidParameter(
                name: "status",
                reason: "unsupported status '\(body.status)'"
            )
        }
        try await assignment.save(on: req.db)
        return req.redirect(to: "/instructor")
    }

    // MARK: - POST /instructor/:assignmentID/close

    @Sendable
    func closeAssignment(req: Request) async throws -> Response {
        let idStr = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db)
        else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(idStr)'")
        }
        assignment.isOpen = false
        try await assignment.save(on: req.db)
        return req.redirect(to: "/instructor")
    }

    // MARK: - POST /instructor/:assignmentID/brightspace

    @Sendable
    func saveBrightSpaceGradeObjectID(req: Request) async throws -> Response {
        let idStr = try assignmentPublicIDParameter(from: req)
        guard let assignment = try await assignmentByPublicID(idStr, on: req.db) else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(idStr)'")
        }
        struct BSBody: Content { var gradeObjectID: String? }
        let body = try req.content.decode(BSBody.self)
        let raw = (body.gradeObjectID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        assignment.brightspaceGradeObjectID = raw.isEmpty ? nil : raw
        try await assignment.save(on: req.db)
        return req.redirect(to: "/instructor/\(idStr)/edit?notice=BrightSpace+grade+item+ID+saved")
    }

    // MARK: - POST /instructor/:assignmentID/delete

    @Sendable
    func deleteAssignment(req: Request) async throws -> Response {
        let idStr = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db)
        else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(idStr)'")
        }
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

        try await assignment.delete(on: req.db)
        return req.redirect(to: "/instructor")
    }

    // MARK: - POST /instructor/setup/:setupID/delete

    @Sendable
    func deleteUnpublishedSetup(req: Request) async throws -> Response {
        let setupID = req.parameters.get("setupID") ?? ""
        guard let setup = try await APITestSetup.find(setupID, on: req.db) else {
            throw WebAssignmentError.notFound(resource: "Test setup '\(setupID)'")
        }
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
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else {
            throw WebAssignmentError.forbidden(action: "edit assignments")
        }

        let idStr = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(idStr)'")
        }
        _ = setup  // keep existence check explicit

        struct EditQuery: Content {
            var assignmentName: String?
            var dueAt: String?
            var error: String?
            var notice: String?
        }
        let q = try? req.query.decode(EditQuery.self)
        let draftSolutionPath = draftSolutionNotebookPath(
            testSetupsDirectory: req.application.testSetupsDirectory, setupID: setup.id!)
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
        let patternFamiliesJSON: String = {
            guard let data = setup.manifest.data(using: .utf8),
                let props = try? ManifestCodec.decoder.decode(TestProperties.self, from: data)
            else { return "[]" }
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            let familyData = (try? enc.encode(props.patternFamilies)) ?? Data("[]".utf8)
            return String(data: familyData, encoding: .utf8) ?? "[]"
        }()
        let notebookChecksJSON: String = {
            guard let data = setup.manifest.data(using: .utf8),
                let props = try? ManifestCodec.decoder.decode(TestProperties.self, from: data)
            else { return "[]" }
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            let checkData = (try? enc.encode(props.notebookChecks)) ?? Data("[]".utf8)
            return String(data: checkData, encoding: .utf8) ?? "[]"
        }()
        let ctx = EditAssignmentContext(
            currentUser: req.currentUserContext,
            assignmentID: idStr,
            testSetupID: setup.id!,
            assignmentName: (q?.assignmentName ?? assignment.title).trimmingCharacters(in: .whitespacesAndNewlines),
            dueAt: q?.dueAt ?? currentDueAt,
            currentAssignmentFile: currentFiles.assignmentFile.name,
            currentAssignmentURL: currentFiles.assignmentFile.url,
            assignmentNotebookEditURL: "/testsetups/\(setup.id!)/notebook?title=\(urlEncode(assignment.title))",
            currentSolutionFile: currentFiles.solutionFile?.name,
            currentSolutionURL: currentFiles.solutionFile?.url,
            solutionNotebookEditURL: currentFiles.solutionFile != nil
                ? "/testsetups/\(setup.id!)/notebook?file=solution&title=\(urlEncode("Solution Notebook"))"
                : nil,
            existingSuiteRows: currentFiles.existingSuiteRows.filter { $0.tier != "support" },
            supportFileRows: currentFiles.existingSuiteRows.filter { $0.tier == "support" },
            familyRows: familySuiteRowsForSetup(setup),
            patternFamiliesJSON: patternFamiliesJSON,
            notebookChecksJSON: notebookChecksJSON,
            suiteStateJSON: suiteStateJSON(fromManifest: setup.manifest),
            suiteSectionRows: suiteSectionShellRows(fromManifest: setup.manifest),
            globalVariableRows: globalVariableShellRows(fromManifest: setup.manifest),
            brightspaceSyncEnabled: req.application.brightSpaceClient != nil,
            brightspaceGradeObjectID: assignment.brightspaceGradeObjectID,
            notice: q?.notice,
            error: q?.error
        )
        return try await req.view.render("assignment-edit", ctx)
    }
}
