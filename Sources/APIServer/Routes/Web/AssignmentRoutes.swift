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

import Vapor
import Fluent
import Core
import Foundation

struct AssignmentRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // Course-scoped instructor actions (not under the /instructor prefix).
        routes.post("courses", ":courseID", "enrollment-mode", use: setCourseEnrollmentMode)
        routes.post("courses", ":courseID", "enroll-csv",      use: instructorBulkEnrollCSV)
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
        r.get("new", "draft", "suite",    use: getDraftSuite)
        r.put("new", "draft", "suite",    use: putDraftSuite)
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
        r.get(":assignmentID", "edit",     use: editPage)
        r.post(":assignmentID", "edit", "save", use: saveEditedAssignment)
        r.get(":assignmentID", "files", "notebook", use: downloadCurrentNotebookFile)
        r.get(":assignmentID", "files", "solution", use: downloadCurrentSolutionFile)
        r.get(":assignmentID", "files", "item", use: downloadCurrentSetupItem)
        r.post(":assignmentID", "brightspace", use: saveBrightSpaceGradeObjectID)
        r.post(":assignmentID", "status",  use: updateStatus)
        r.post(":assignmentID", "open",    use: openAssignment)
        r.post(":assignmentID", "close",   use: closeAssignment)
        r.post(":assignmentID", "delete",  use: deleteAssignment)
        r.post("setup", ":setupID", "delete", use: deleteUnpublishedSetup)
        r.post(":assignmentID", "create-solution", use: createSolutionFromAssignment)

        // Script editor — inline CRUD for individual test/support files in the setup zip.
        r.get("script-templates", use: getScriptTemplates)
        r.post("scan-notebook", use: scanNotebook)
        r.get(":assignmentID",  "scripts", ":filename", use: getScript)
        r.put(":assignmentID",  "scripts", ":filename", use: updateScript)
        r.post(":assignmentID", "scripts",              use: createScript)
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
        r.post(":assignmentID", "suite-sections",                      use: createSuiteSection)
        r.post(":assignmentID", "suite-sections", "reorder",           use: reorderSuiteSections)
        r.post(":assignmentID", "suite-sections", ":sectionID", "rename", use: renameSuiteSection)
        r.post(":assignmentID", "suite-sections", ":sectionID", "delete", use: deleteSuiteSection)
        r.post(":assignmentID", "suite-sections", ":sectionID", "variables", use: updateSuiteSectionVariables)
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
           let activeCourseModel = try await APICourse.find(activeCourseUUID, on: req.db) {
            courseEnrollmentMode = activeCourseModel.enrollmentMode.rawValue
            courseIsArchived     = activeCourseModel.isArchived
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

    // MARK: - GET /instructor/new

    @Sendable
    func newAssignmentPage(req: Request) async throws -> View {
        struct NewQuery: Content {
            var assignmentName: String?
            var dueAt: String?
            var error: String?
            var notice: String?
            var sectionID: String?
            var draftID: String?
        }
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else {
            throw WebAssignmentError.forbidden(action: "open the new-assignment page")
        }
        let courseState = try await req.resolveActiveCourse(for: user)
        let q = (try? req.query.decode(NewQuery.self))

        let sections = try await loadNewAssignmentSectionPicker(
            req: req,
            activeCourseUUID: courseState.activeCourseUUID
        )

        let draftID = (q?.draftID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let setup = draftID.isEmpty ? nil : try await APITestSetup.find(draftID, on: req.db)
        let storedState = setup == nil ? NewAssignmentDraftFormState.empty : loadDraftFormState(req: req, draftID: draftID)

        let assignmentNotebook = newAssignmentNotebookContext(setup: setup, storedState: storedState)
        let solutionNotebook = newAssignmentSolutionNotebookContext(
            req: req,
            userID: userID,
            setup: setup,
            storedState: storedState
        )

        let suiteRows = setup.map(editableSuiteRowsForSetup) ?? []
        let supportFileRows = newAssignmentSupportFileRows(setup: setup, suiteRows: suiteRows)
        let detected = newAssignmentRequirementSuggestions(req: req, userID: userID, setup: setup)

        let assignmentName = (q?.assignmentName ?? storedState.assignmentName).trimmingCharacters(in: .whitespacesAndNewlines)
        let dueAt = q?.dueAt ?? storedState.dueAt
        let selectedSectionID = q?.sectionID ?? storedState.sectionID

        let ctx = NewAssignmentContext(
            currentUser: req.currentUserContext,
            assignmentName: assignmentName,
            dueAt: dueAt,
            sections: sections,
            preselectedSectionID: selectedSectionID,
            draftID: setup?.id,
            draftIDJSON: newAssignmentDraftIDJSON(setup: setup),
            assignmentNotebook: assignmentNotebook,
            solutionNotebook: solutionNotebook,
            suiteRows: suiteRows,
            hasSuiteRows: !suiteRows.isEmpty,
            supportFileRows: supportFileRows,
            patternFamiliesJSON: newAssignmentPatternFamiliesJSON(setup: setup),
            notebookChecksJSON: newAssignmentNotebookChecksJSON(setup: setup),
            suiteStateJSON: newAssignmentSuiteStateSeedJSON(setup: setup),
            suiteSectionRows: newAssignmentSuiteSectionShellRows(setup: setup),
            requiredPlatform: storedState.requiredPlatform,
            requiredArchitecture: storedState.requiredArchitecture,
            requiredLanguagesCSV: storedState.requiredLanguagesCSV.isEmpty
                ? detected.languages.joined(separator: ", ")
                : storedState.requiredLanguagesCSV,
            requiredCapabilitiesCSV: storedState.requiredCapabilitiesCSV.isEmpty
                ? detected.capabilities.joined(separator: ", ")
                : storedState.requiredCapabilitiesCSV,
            detectedLanguages: detected.languages,
            detectedCapabilities: detected.capabilities,
            detectedLanguagesCSV: detected.languages.joined(separator: ", "),
            detectedCapabilitiesCSV: detected.capabilities.joined(separator: ", "),
            notice: q?.notice,
            error: q?.error
        )
        return try await req.view.render("assignment-new", ctx)
    }

    @Sendable
    func updateNewAssignmentDraft(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else {
            throw WebAssignmentError.forbidden(action: "edit a new-assignment draft")
        }
        let courseState = try await req.resolveActiveCourse(for: user)
        guard let courseID = courseState.activeCourseUUID else {
            throw WebAssignmentError.noActiveCourse(action: "creating an assignment")
        }

        struct DraftBodyMany: Content {
            var assignmentName: String?
            var dueAt: String?
            var sectionID: String?
            var draftID: String?
            var draftAction: String?
            var assignmentNotebookFile: File?
            var solutionNotebookFile: File?
            var suiteFiles: [File]?
            var suiteConfig: String?
            var requiredPlatform: String?
            var requiredArchitecture: String?
            var requiredLanguagesCSV: String?
            var requiredCapabilitiesCSV: String?
        }
        struct DraftBodySingle: Content {
            var assignmentName: String?
            var dueAt: String?
            var sectionID: String?
            var draftID: String?
            var draftAction: String?
            var assignmentNotebookFile: File?
            var solutionNotebookFile: File?
            var suiteFiles: File?
            var suiteConfig: String?
            var requiredPlatform: String?
            var requiredArchitecture: String?
            var requiredLanguagesCSV: String?
            var requiredCapabilitiesCSV: String?
        }

        let bodyMany = try? req.content.decode(DraftBodyMany.self)
        let bodySingle = bodyMany == nil ? (try? req.content.decode(DraftBodySingle.self)) : nil
        guard bodyMany != nil || bodySingle != nil else {
            throw WebAssignmentError.invalidParameter(name: "request body", reason: "Invalid assignment draft payload")
        }

        let assignmentName = try multipartTextField(named: ["assignmentName"], from: req)
            ?? bodyMany?.assignmentName
            ?? bodySingle?.assignmentName
            ?? ""
        let dueAt = try multipartTextField(named: ["dueAt"], from: req)
            ?? bodyMany?.dueAt
            ?? bodySingle?.dueAt
            ?? ""
        let sectionIDRaw = try multipartTextField(named: ["sectionID"], from: req)
            ?? bodyMany?.sectionID
            ?? bodySingle?.sectionID
            ?? ""
        let draftIDRaw = try multipartTextField(named: ["draftID"], from: req)
            ?? bodyMany?.draftID
            ?? bodySingle?.draftID
        let action = (try multipartTextField(named: ["draftAction"], from: req)
            ?? bodyMany?.draftAction
            ?? bodySingle?.draftAction
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let assignmentNotebookFile = bodyMany?.assignmentNotebookFile ?? bodySingle?.assignmentNotebookFile
        let solutionNotebookFile = bodyMany?.solutionNotebookFile ?? bodySingle?.solutionNotebookFile
        let suiteFiles = (try multipartFiles(named: ["suiteFiles[]", "suiteFiles"], from: req)
            ?? bodyMany?.suiteFiles
            ?? (bodySingle?.suiteFiles.map { [$0] } ?? []))
            .filter { $0.data.readableBytes > 0 }
        let suiteConfigRaw = try multipartTextField(named: ["suiteConfig"], from: req)
            ?? bodyMany?.suiteConfig
            ?? bodySingle?.suiteConfig
        let requiredPlatform = try multipartTextField(named: ["requiredPlatform"], from: req)
            ?? bodyMany?.requiredPlatform
            ?? bodySingle?.requiredPlatform
            ?? ""
        let requiredArchitecture = try multipartTextField(named: ["requiredArchitecture"], from: req)
            ?? bodyMany?.requiredArchitecture
            ?? bodySingle?.requiredArchitecture
            ?? ""
        let requiredLanguagesCSV = try multipartTextField(named: ["requiredLanguagesCSV"], from: req)
            ?? bodyMany?.requiredLanguagesCSV
            ?? bodySingle?.requiredLanguagesCSV
            ?? ""
        let requiredCapabilitiesCSV = try multipartTextField(named: ["requiredCapabilitiesCSV"], from: req)
            ?? bodyMany?.requiredCapabilitiesCSV
            ?? bodySingle?.requiredCapabilitiesCSV
            ?? ""

        let setup = try await resolveOrCreateNewAssignmentDraft(
            req: req,
            courseID: courseID,
            draftID: draftIDRaw,
            sectionIDRaw: sectionIDRaw
        )

        var formState = loadDraftFormState(req: req, draftID: setup.id!)
        formState.assignmentName = assignmentName
        formState.dueAt = dueAt
        formState.sectionID = sectionIDRaw
        formState.requiredPlatform = requiredPlatform
        formState.requiredArchitecture = requiredArchitecture
        formState.requiredLanguagesCSV = requiredLanguagesCSV
        formState.requiredCapabilitiesCSV = requiredCapabilitiesCSV

        let actionTitle = assignmentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let notebookTitle = actionTitle.isEmpty ? "New Assignment" : actionTitle

        switch action {
        case "create-assignment-notebook":
            let data = defaultNotebookData(title: notebookTitle)
            let dir = try ensureDraftNotebookDirectory(testSetupsDirectory: req.application.testSetupsDirectory, setupID: setup.id!)
            let path = dir + "assignment.ipynb"
            try data.write(to: URL(fileURLWithPath: path))
            setup.notebookPath = path
            try await setup.save(on: req.db)
            _ = try await ensureUserNotebookWorkingCopy(
                req: req,
                setupID: setup.id!,
                userID: userID,
                fallbackSetup: setup,
                overwriteWith: data
            )
            formState.assignmentNotebookName = "assignment.ipynb"
        case "upload-assignment-notebook":
            guard let assignmentNotebookFile, assignmentNotebookFile.data.readableBytes > 0 else {
                return redirectToNewAssignmentDraft(
                    req: req,
                    draftID: setup.id!,
                    assignmentName: assignmentName,
                    dueAt: dueAt,
                    sectionID: sectionIDRaw,
                    notice: nil,
                    error: "Select an assignment notebook to upload"
                )
            }
            let raw = Data(assignmentNotebookFile.data.readableBytesView)
            guard (try? JSONSerialization.jsonObject(with: raw)) != nil else {
                return redirectToNewAssignmentDraft(
                    req: req,
                    draftID: setup.id!,
                    assignmentName: assignmentName,
                    dueAt: dueAt,
                    sectionID: sectionIDRaw,
                    notice: nil,
                    error: "Assignment notebook must be valid JSON (.ipynb)"
                )
            }
            let normalized = normalizeNotebookForJupyterLite(raw)
            let dir = try ensureDraftNotebookDirectory(testSetupsDirectory: req.application.testSetupsDirectory, setupID: setup.id!)
            let filename = notebookFilenameForStorage(uploadedName: assignmentNotebookFile.filename, fallback: "assignment.ipynb")
            let path = dir + filename
            try normalized.write(to: URL(fileURLWithPath: path))
            setup.notebookPath = path
            try await setup.save(on: req.db)
            _ = try await ensureUserNotebookWorkingCopy(
                req: req,
                setupID: setup.id!,
                userID: userID,
                fallbackSetup: setup,
                overwriteWith: normalized
            )
            formState.assignmentNotebookName = filename
        case "clear-assignment-notebook":
            removeDraftNotebookFiles(
                req: req,
                setupID: setup.id!,
                userID: userID,
                fileKind: .assignment,
                persistedPath: setup.notebookPath
            )
            setup.notebookPath = nil
            try await setup.save(on: req.db)
            formState.assignmentNotebookName = nil
        case "create-solution-notebook":
            let data = defaultNotebookData(title: "\(notebookTitle) Solution")
            let path = draftSolutionNotebookPath(testSetupsDirectory: req.application.testSetupsDirectory, setupID: setup.id!)
            _ = try ensureDraftNotebookDirectory(testSetupsDirectory: req.application.testSetupsDirectory, setupID: setup.id!)
            try data.write(to: URL(fileURLWithPath: path))
            _ = try await ensureUserNotebookWorkingCopy(
                req: req,
                setupID: setup.id!,
                userID: userID,
                fallbackSetup: setup,
                relativePath: userNotebookWorkingCopyRelativePath(setupID: setup.id!, userID: userID, fileKind: .solution),
                overwriteWith: data
            )
            formState.solutionNotebookName = "solution.ipynb"
        case "create-solution-from-assignment":
            // Parity PR 4 of #433.  Mirrors the assignment-scoped
            // `createSolutionFromAssignment` (POST /:id/create-solution):
            // copy the assignment notebook bytes into the draft solution
            // path so the instructor can author the answer key starting
            // from the student-facing notebook.  Falls back to a blank
            // notebook with the title suffix " Solution" when the
            // assignment notebook isn't readable yet — same fallback
            // the assignment-scoped variant uses.
            let sourceData: Data = {
                if let path = setup.notebookPath,
                   let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)),
                   !bytes.isEmpty {
                    return bytes
                }
                return defaultNotebookData(title: "\(notebookTitle) Solution")
            }()
            let normalized = normalizeNotebookForJupyterLite(sourceData)
            let path = draftSolutionNotebookPath(testSetupsDirectory: req.application.testSetupsDirectory, setupID: setup.id!)
            _ = try ensureDraftNotebookDirectory(testSetupsDirectory: req.application.testSetupsDirectory, setupID: setup.id!)
            try normalized.write(to: URL(fileURLWithPath: path))
            _ = try await ensureUserNotebookWorkingCopy(
                req: req,
                setupID: setup.id!,
                userID: userID,
                fallbackSetup: setup,
                relativePath: userNotebookWorkingCopyRelativePath(setupID: setup.id!, userID: userID, fileKind: .solution),
                overwriteWith: normalized
            )
            formState.solutionNotebookName = "solution.ipynb"
        case "upload-solution-notebook":
            guard let solutionNotebookFile, solutionNotebookFile.data.readableBytes > 0 else {
                return redirectToNewAssignmentDraft(
                    req: req,
                    draftID: setup.id!,
                    assignmentName: assignmentName,
                    dueAt: dueAt,
                    sectionID: sectionIDRaw,
                    notice: nil,
                    error: "Select a solution notebook to upload"
                )
            }
            let raw = Data(solutionNotebookFile.data.readableBytesView)
            guard (try? JSONSerialization.jsonObject(with: raw)) != nil else {
                return redirectToNewAssignmentDraft(
                    req: req,
                    draftID: setup.id!,
                    assignmentName: assignmentName,
                    dueAt: dueAt,
                    sectionID: sectionIDRaw,
                    notice: nil,
                    error: "Solution notebook must be valid JSON (.ipynb)"
                )
            }
            let normalized = normalizeNotebookForJupyterLite(raw)
            let path = draftSolutionNotebookPath(testSetupsDirectory: req.application.testSetupsDirectory, setupID: setup.id!)
            _ = try ensureDraftNotebookDirectory(testSetupsDirectory: req.application.testSetupsDirectory, setupID: setup.id!)
            try normalized.write(to: URL(fileURLWithPath: path))
            _ = try await ensureUserNotebookWorkingCopy(
                req: req,
                setupID: setup.id!,
                userID: userID,
                fallbackSetup: setup,
                relativePath: userNotebookWorkingCopyRelativePath(setupID: setup.id!, userID: userID, fileKind: .solution),
                overwriteWith: normalized
            )
            formState.solutionNotebookName = notebookFilenameForStorage(uploadedName: solutionNotebookFile.filename, fallback: "solution.ipynb")

            // v0.4.100: auto-scan the solution for `##` sections and
            // top-level function defs, then scaffold one `publictest_
            // exists_<fn>.py` per detected function, placed in the
            // section whose `##` header most recently preceded it.
            // One-shot: silently skips if the manifest already has
            // sections / test entries.  Errors are swallowed — this is
            // a nice-to-have that must not block the upload.
            do {
                let result = try await autoScaffoldFromSolutionNotebook(
                    setup: setup,
                    notebookData: normalized,
                    zipPath: setup.zipPath,
                    on: req.db
                )
                if result.functions > 0 {
                    req.logger.info("auto_scaffold sections=\(result.sections) functions=\(result.functions) setup=\(setup.id ?? "?")")
                }
            } catch {
                req.logger.warning("auto_scaffold_failed setup=\(setup.id ?? "?") error=\(error)")
            }
        case "clear-solution-notebook":
            removeDraftNotebookFiles(
                req: req,
                setupID: setup.id!,
                userID: userID,
                fileKind: .solution,
                persistedPath: draftSolutionNotebookPath(testSetupsDirectory: req.application.testSetupsDirectory, setupID: setup.id!)
            )
            formState.solutionNotebookName = nil
        case "replace-suite-files":
            let setupPackage = try createRunnerSetupZip(
                suiteFiles: suiteFiles,
                suiteConfigJSON: suiteConfigRaw,
                zipPath: setup.zipPath
            )
            let sectionGradingMode = try await newAssignmentSectionGradingMode(
                req: req,
                courseID: courseID,
                sectionIDRaw: sectionIDRaw
            )
            let starterNotebook = setup.notebookPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "assignment.ipynb"
            setup.manifest = try makeWorkerManifestJSON(
                testSuites: setupPackage.testSuites,
                includeMakefile: setupPackage.hasMakefile,
                gradingMode: sectionGradingMode,
                starterNotebook: starterNotebook
            )
            try await setup.save(on: req.db)
            extractSupportFilesToSharedDirectory(
                zipPath: setup.zipPath,
                setupID: setup.id!,
                testSuiteScripts: Set(setupPackage.testSuites.map { $0.script }),
                testSetupsDirectory: req.application.testSetupsDirectory
            )
        case "clear-suite-files":
            let starterNotebook = setup.notebookPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "assignment.ipynb"
            _ = try createRunnerSetupZip(suiteFiles: [], suiteConfigJSON: nil, zipPath: setup.zipPath)
            setup.manifest = try makeWorkerManifestJSON(
                testSuites: [],
                includeMakefile: false,
                gradingMode: try await newAssignmentSectionGradingMode(req: req, courseID: courseID, sectionIDRaw: sectionIDRaw),
                starterNotebook: starterNotebook
            )
            try await setup.save(on: req.db)
        default:
            break
        }

        saveDraftFormState(req: req, draftID: setup.id!, state: formState)

        return redirectToNewAssignmentDraft(
            req: req,
            draftID: setup.id!,
            assignmentName: assignmentName,
            dueAt: dueAt,
            sectionID: sectionIDRaw,
            notice: nil,
            error: nil
        )
    }

    // MARK: - POST /instructor/new/save

    @Sendable
    func saveNewAssignment(req: Request) async throws -> Response {
        let saveUser = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: saveUser)
        guard let courseID = courseState.activeCourseUUID else {
            throw WebAssignmentError.noActiveCourse(action: "creating an assignment")
        }

        let form = try parseSaveNewAssignmentForm(req: req)
        let validation = try await validateSaveNewAssignment(
            req: req,
            saveUserID: saveUser.id,
            form: form
        )
        let validated: ValidatedSaveNewAssignment
        switch validation {
        case .valid(let v): validated = v
        case .redirect(toURL: let url): return req.redirect(to: url)
        }

        let title = validated.title
        let due = validated.dueAt
        let dueAtRaw = validated.dueAtRaw
        let sectionIDRaw = validated.sectionIDRaw
        let draftID = validated.draftID
        let draftSetup = validated.draftSetup
        let draftState = validated.draftState
        let assignmentNotebookRaw = validated.assignmentNotebookRaw
        let solutionNotebookRaw = validated.solutionNotebookRaw
        let uploadedAssignmentNotebookFilename = validated.uploadedAssignmentNotebookFilename
        let uploadedSolutionNotebookFilename = validated.uploadedSolutionNotebookFilename
        let suiteFiles = validated.suiteFiles
        let suiteConfigRaw = validated.suiteConfigRaw
        let requirementSpec = validated.requirementSpec

        let assignmentNotebook = normalizeNotebookForJupyterLite(assignmentNotebookRaw)
        let setupID = draftSetup?.id ?? "setup_\(UUID().uuidString.lowercased().prefix(8))"
        let setupsDir = req.application.testSetupsDirectory
        let notebookFilename = notebookFilenameForStorage(
            uploadedName: uploadedAssignmentNotebookFilename ?? draftState.assignmentNotebookName,
            fallback: draftSetup?.notebookPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "assignment.ipynb"
        )
        let notebookDir = setupsDir + "notebooks/\(setupID)/"
        try FileManager.default.createDirectory(atPath: notebookDir, withIntermediateDirectories: true)
        let notebookPath = notebookDir + notebookFilename
        let zipPath = draftSetup?.zipPath ?? (setupsDir + "\(setupID).zip")
        try assignmentNotebook.write(to: URL(fileURLWithPath: notebookPath))
        let resolvedSuiteFiles: [File] = {
            if !suiteFiles.isEmpty { return suiteFiles }
            guard let draftSetup else { return [] }
            return editableSuiteRowsForSetup(draftSetup).compactMap { row in
                guard let data = extractZipEntry(zipPath: draftSetup.zipPath, entryName: row.name) else { return nil }
                var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                buffer.writeBytes(data)
                return File(data: buffer, filename: row.name)
            }
        }()
        let resolvedSuiteConfigJSON: String? = {
            if let suiteConfigRaw, !suiteConfigRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return suiteConfigRaw
            }
            return draftSetup?.manifest.data(using: .utf8).flatMap { data in
                guard let props = try? ManifestCodec.decoder.decode(TestProperties.self, from: data) else { return nil }
                let rows = props.testSuites.enumerated().map { index, entry in
                    ReindexedSuiteConfigRow(
                        index: index,
                        isTest: entry.tier.rawValue != "support",
                        tier: entry.tier.rawValue,
                        order: index + 1,
                        dependsOn: entry.dependsOn,
                        points: entry.points,
                        displayName: entry.name
                    )
                }
                guard let encoded = try? JSONEncoder().encode(rows) else { return nil }
                return String(data: encoded, encoding: .utf8)
            }
        }()
        // Merge 'existing' (name-based) config rows with files from the draft ZIP so
        // buildSuiteEntries can decode every row using its required `index` field.
        let (mergedSuiteFiles, mergedConfigJSON) = mergeExistingFilesIntoSuiteFiles(
            suiteFiles: resolvedSuiteFiles,
            suiteConfigJSON: resolvedSuiteConfigJSON,
            draftZipPath: draftSetup?.zipPath
        )
        let setupPackage = try createRunnerSetupZip(
            suiteFiles: mergedSuiteFiles,
            suiteConfigJSON: mergedConfigJSON,
            zipPath: zipPath
        )

        // Resolve the section up front so we can inherit its grading mode.
        let resolvedSectionID: UUID? = try await resolveSectionID(sectionIDRaw, courseID: courseID, db: req.db)
        let sectionGradingMode: String
        if let sid = resolvedSectionID,
           let sec = try await APICourseSection.find(sid, on: req.db) {
            sectionGradingMode = sec.defaultGradingMode   // "browser" | "worker"
        } else {
            sectionGradingMode = "worker"
        }

        // Preserve the draft's pattern families, sections, and notebook
        // checks across the manifest rebuild.  Each was added on a
        // different version (v0.4.77 for families, v0.4.96 for sections,
        // v0.4.113 for checks); without forwarding all three,
        // `makeWorkerManifestJSON` emits empty fields and any
        // sections / checks / families authored on the create page get
        // dropped on publish.  Regression guard:
        // `testCreatePublishPreservesSectionsAndChecks`.
        let draftProps: TestProperties? = {
            guard let existingManifest = draftSetup?.manifest,
                  let data = existingManifest.data(using: .utf8) else { return nil }
            return try? ManifestCodec.decoder.decode(TestProperties.self, from: data)
        }()
        let existingFamilies: [PatternFamily] = draftProps?.patternFamilies ?? []
        let existingChecks:   [NotebookCheck] = draftProps?.notebookChecks  ?? []
        let existingSections: [TestSuiteSection] = draftProps?.sections     ?? []

        let manifest = try makeWorkerManifestJSON(
            testSuites: setupPackage.testSuites,
            includeMakefile: setupPackage.hasMakefile,
            gradingMode: sectionGradingMode,
            patternFamilies: existingFamilies,
            notebookChecks: existingChecks,
            sections: existingSections
        )
        let setup = draftSetup ?? APITestSetup(
            id: setupID,
            manifest: manifest,
            zipPath: zipPath,
            notebookPath: notebookPath,
            courseID: courseID
        )
        setup.manifest = manifest
        setup.zipPath = zipPath
        setup.notebookPath = notebookPath
        setup.courseID = courseID
        try await setup.save(on: req.db)

        // Re-run applyPatternFamilies so generated scripts survive the
        // zip rebuild AND so each entry's `sectionID` is restored —
        // `setupPackage.testSuites` loses sectionID through the
        // ReindexedSuiteConfigRow JSON round-trip, and the `authoredItems`
        // path is the only one that re-stamps it from the draft manifest.
        // Run unconditionally when ANY of families / checks / sections
        // exist; the previous gate (families-only) silently dropped
        // sections + checks on publish.
        let needsApply = !existingFamilies.isEmpty
            || !existingChecks.isEmpty
            || !existingSections.isEmpty
        if needsApply {
            let authoredItems = authoredSuiteItemsFromDraftManifest(
                draftProps: draftProps,
                newRawEntries: setupPackage.testSuites
            )
            _ = try await applyPatternFamilies(
                to: setup,
                nextFamilies: existingFamilies,
                nextChecks: existingChecks.isEmpty ? nil : existingChecks,
                authoredItems: authoredItems,
                sections: existingSections.isEmpty ? nil : existingSections,
                on: req.db
            )
        }
        extractSupportFilesToSharedDirectory(
            zipPath: zipPath,
            setupID: setupID,
            testSuiteScripts: Set(setupPackage.testSuites.map { $0.script }),
            testSetupsDirectory: req.application.testSetupsDirectory
        )

        let shouldQueueValidation = !setupPackage.testSuites.isEmpty
        if shouldQueueValidation {
            let hasEligibleRunner = try await ensureCompatibleValidationRunnerAvailability(
                req: req,
                requirements: requirementSpec
            )
            guard hasEligibleRunner else {
                return redirectToNewAssignmentDraft(
                    req: req,
                    draftID: draftID,
                    assignmentName: title,
                    dueAt: dueAtRaw,
                    sectionID: sectionIDRaw,
                    notice: nil,
                    error: "No compatible active runner is available to validate this assignment."
                )
            }
        }

        let assignment = try await createAssignmentWithUniquePublicID(
            req: req,
            testSetupID: setupID,
            title: title,
            dueAt: due,
            isOpen: false,
            sortOrder: try await nextAssignmentSortOrder(req: req),
            validationStatus: shouldQueueValidation ? "pending" : nil,
            validationSubmissionID: nil,
            sectionID: resolvedSectionID,
            courseID: courseID
        )
        if let requirements = requirementSpec {
            let requirement = AssignmentRequirement(
                assignmentID: try assignment.requireID(),
                specification: requirements
            )
            try await requirement.save(on: req.db)
        }

        if shouldQueueValidation {
            let validationSubmissionID = try await enqueueRunnerValidationSubmission(
                req: req,
                setupID: setupID,
                solutionNotebookData: normalizeNotebookForJupyterLite(solutionNotebookRaw),
                filename: uploadedSolutionNotebookFilename
                    ?? draftState.solutionNotebookName
                    ?? "solution.ipynb"
            )
            assignment.validationSubmissionID = validationSubmissionID
            try await assignment.save(on: req.db)
            await ensureValidationRunnerAvailability(req: req)
        }
        if !draftID.isEmpty {
            clearDraftFormState(req: req, draftID: draftID)
        }
        return req.redirect(to: "/instructor")
    }

    // MARK: - POST /instructor
    // Creates a draft (isOpen: false) assignment and redirects to the validate page.

    private func redirectToNewAssignmentDraft(
        req: Request,
        draftID: String,
        assignmentName: String,
        dueAt: String,
        sectionID: String,
        notice: String?,
        error: String?
    ) -> Response {
        var parts: [String] = [
            "draftID=\(urlEncode(draftID))",
            "assignmentName=\(urlEncode(assignmentName))",
            "dueAt=\(urlEncode(dueAt))",
            "sectionID=\(urlEncode(sectionID))"
        ]
        if let notice, !notice.isEmpty {
            parts.append("notice=\(urlEncode(notice))")
        }
        if let error, !error.isEmpty {
            parts.append("error=\(urlEncode(error))")
        }
        return req.redirect(to: "/instructor/new?\(parts.joined(separator: "&"))")
    }

    private func resolveOrCreateNewAssignmentDraft(
        req: Request,
        courseID: UUID,
        draftID: String?,
        sectionIDRaw: String
    ) async throws -> APITestSetup {
        if let draftID,
           !draftID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let existing = try await APITestSetup.find(draftID, on: req.db) {
            return existing
        }

        let setupID = "setup_\(UUID().uuidString.lowercased().prefix(8))"
        let zipPath = req.application.testSetupsDirectory + "\(setupID).zip"
        _ = try createRunnerSetupZip(suiteFiles: [], suiteConfigJSON: nil, zipPath: zipPath)
        let gradingMode = try await newAssignmentSectionGradingMode(
            req: req,
            courseID: courseID,
            sectionIDRaw: sectionIDRaw
        )
        let manifest = try makeWorkerManifestJSON(
            testSuites: [],
            includeMakefile: false,
            gradingMode: gradingMode,
            starterNotebook: "assignment.ipynb"
        )
        let setup = APITestSetup(
            id: setupID,
            manifest: manifest,
            zipPath: zipPath,
            notebookPath: nil,
            courseID: courseID
        )
        try await setup.save(on: req.db)
        return setup
    }

    private func newAssignmentSectionGradingMode(
        req: Request,
        courseID: UUID,
        sectionIDRaw: String
    ) async throws -> String {
        guard let sid = try await resolveSectionID(sectionIDRaw, courseID: courseID, db: req.db),
              let sec = try await APICourseSection.find(sid, on: req.db) else {
            return "worker"
        }
        return sec.defaultGradingMode
    }

    @Sendable
    func publish(req: Request) async throws -> Response {
        struct PublishBody: Content {
            var testSetupID: String
            var title: String
            var dueAt: String?      // ISO8601 string from datetime-local input, or empty
        }

        let publishUser = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: publishUser)
        let body = try req.content.decode(PublishBody.self)

        guard let _ = try await APITestSetup.find(body.testSetupID, on: req.db) else {
            throw WebAssignmentError.invalidParameter(
                name: "testSetupID",
                reason: "unknown test setup '\(body.testSetupID)'"
            )
        }

        // Reject if a draft/open assignment already exists for this setup.
        let existing = try await APIAssignment.query(on: req.db)
            .filter(\.$testSetupID == body.testSetupID)
            .count()
        if existing > 0 {
            // Already published — redirect back.
            return req.redirect(to: "/instructor")
        }

        let due: Date?
        if let raw = body.dueAt, !raw.isEmpty {
            // datetime-local sends "2026-04-01T14:00" — try ISO8601 with and without seconds.
            let iso = ISO8601DateFormatter()
            if let d = iso.date(from: raw) {
                due = d
            } else {
                // Try without timezone (datetime-local format)
                let fmt = DateFormatter()
                fmt.locale = Locale(identifier: "en_US_POSIX")
                fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
                due = fmt.date(from: raw)
            }
        } else {
            due = nil
        }

        guard let courseID = courseState.activeCourseUUID else {
            throw WebAssignmentError.noActiveCourse(action: "publishing an assignment")
        }

        let assignment = try await createAssignmentWithUniquePublicID(
            req: req,
            testSetupID: body.testSetupID,
            title: body.title.isEmpty ? body.testSetupID : body.title,
            dueAt: due,
            isOpen: false,         // stays closed until instructor validates + opens
            sortOrder: try await nextAssignmentSortOrder(req: req),
            courseID: courseID
        )
        return req.redirect(to: "/instructor/\(assignment.publicID)/validate")
    }

    // MARK: - GET /instructor/:assignmentID/validate

    @Sendable
    func validatePage(req: Request) async throws -> View {
        let idStr = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup      = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(idStr)'")
        }

        let suiteCount: Int = {
            guard let data  = setup.manifest.data(using: .utf8),
                  let props = try? ManifestCodec.decoder.decode(TestProperties.self, from: data)
            else { return 0 }
            return props.testSuites.count
        }()

        let fmt = waterlooDateTimeFormatter()

        let ctx = ValidateContext(
            currentUser:  req.currentUserContext,
            assignmentID: idStr,
            setupID:      assignment.testSetupID,
            title:        assignment.title,
            suiteCount:   suiteCount,
            dueAt:        assignment.dueAt.map { fmt.string(from: $0) }
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
        let hasAssignment = try await APIAssignment.query(on: req.db)
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
            let setup      = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(idStr)'")
        }
        _ = setup // keep existence check explicit

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
        let fallbackSolutionFilename = (assignment.validationStatus == "passed"
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
            brightspaceSyncEnabled: req.application.brightSpaceClient != nil,
            brightspaceGradeObjectID: assignment.brightspaceGradeObjectID,
            notice: q?.notice,
            error: q?.error
        )
        return try await req.view.render("assignment-edit", ctx)
    }

}
