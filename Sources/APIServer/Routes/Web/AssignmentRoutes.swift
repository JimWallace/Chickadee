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
//   POST /instructor/:assignmentID/section         → move assignment to a section (or ungrouped)
//   POST /instructor/sections                      → create a new course section
//   POST /instructor/sections/reorder              → reorder sections
//   POST /instructor/sections/:sectionID/rename    → rename/reconfigure a section
//   POST /instructor/sections/:sectionID/delete    → delete a section

import Vapor
import Fluent
import Core
import Foundation
import Crypto

struct AssignmentRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // Course-scoped instructor actions (not under the /instructor prefix).
        routes.post("courses", ":courseID", "enrollment-mode", use: setCourseEnrollmentMode)
        routes.post("courses", ":courseID", "enroll-csv",      use: instructorBulkEnrollCSV)

        let r = routes.grouped("instructor")
        r.get(use: list)
        r.get("grades.csv", use: exportGradesCSV)
        r.get("students", ":studentID", "submissions", use: courseStudentSubmissionsPage)
        r.get(":assignmentID", "submissions", use: assignmentSubmissionsPage)
        r.get(":assignmentID", "students", ":studentID", "history", use: studentSubmissionHistoryPage)
        r.post(":assignmentID", "submissions", ":submissionID", "retest", use: retestSubmission)
        r.get("new", use: newAssignmentPage)
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
        r.post(":assignmentID", "status",  use: updateStatus)
        r.post(":assignmentID", "open",    use: openAssignment)
        r.post(":assignmentID", "close",   use: closeAssignment)
        r.post(":assignmentID", "delete",  use: deleteAssignment)

        // Script editor — inline CRUD for individual test/support files in the setup zip.
        r.post("scan-notebook", use: scanNotebook)
        r.get(":assignmentID",  "scripts", ":filename", use: getScript)
        r.put(":assignmentID",  "scripts", ":filename", use: updateScript)
        r.post(":assignmentID", "scripts",              use: createScript)
        r.delete(":assignmentID", "scripts", ":filename", use: deleteScript)
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

        let allSetups: [APITestSetup]
        if let activeCourseUUID = courseState.activeCourseUUID {
            allSetups = try await APITestSetup.query(on: req.db)
                .filter(\.$courseID == activeCourseUUID)
                .sort(\.$createdAt, .descending)
                .all()
        } else {
            allSetups = try await APITestSetup.query(on: req.db)
                .sort(\.$createdAt, .descending)
                .all()
        }

        let allAssignments: [APIAssignment]
        if let activeCourseUUID = courseState.activeCourseUUID {
            allAssignments = try await APIAssignment.query(on: req.db)
                .filter(\.$courseID == activeCourseUUID)
                .all()
        } else {
            allAssignments = try await APIAssignment.query(on: req.db).all()
        }
        // Map testSetupID → assignment for quick lookup
        let assignmentBySetup = Dictionary(
            allAssignments.map { ($0.testSetupID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        let isoFormatter = ISO8601DateFormatter()

        let decoder = JSONDecoder()

        let setupIndexByID: [String: Int] = Dictionary(
            uniqueKeysWithValues: allSetups.enumerated().map { ($0.element.id ?? "", $0.offset) }
        )
        let allSetupIDs = allSetups.compactMap { $0.id }

        let enrolledStudents: [EnrolledStudentRow]
        let metrics: [InstructorDashboardMetric]
        if let activeCourseUUID = courseState.activeCourseUUID {
            let enrollments = try await APICourseEnrollment.query(on: req.db)
                .filter(\.$course.$id == activeCourseUUID)
                .all()
            let enrolledUserIDs = enrollments.map(\.userID)
            let enrolledUsers: [APIUser]

            if enrolledUserIDs.isEmpty {
                enrolledUsers = []
                enrolledStudents = []
            } else {
                enrolledUsers = try await APIUser.query(on: req.db)
                    .filter(\.$id ~~ enrolledUserIDs)
                    .sort(\.$username)
                    .all()
                enrolledStudents = enrolledUsers.compactMap { u in
                    guard let id = u.id else { return nil }
                    return EnrolledStudentRow(
                        id: id.uuidString,
                        username: u.username,
                        displayName: u.displayName ?? u.username,
                        role: u.role,
                        lastLoginAtText: u.lastLoginAt.map { fmt.string(from: $0) } ?? "—",
                        lastLoginAtISO: u.lastLoginAt.map { isoFormatter.string(from: $0) },
                        submissionsURL: "/instructor/students/\(id.uuidString)/submissions"
                    )
                }
            }

            let now = Date()
            let windowStart = now.addingTimeInterval(-24 * 60 * 60)
            let courseSetupIDs = allSetupIDs
            let recentSubmissions = courseSetupIDs.isEmpty ? [] : try await APISubmission.query(on: req.db)
                .filter(\.$testSetupID ~~ courseSetupIDs)
                .filter(\.$kind == APISubmission.Kind.student)
                .filter(\.$submittedAt >= windowStart)
                .all()
            let allCourseStudentSubmissions = courseSetupIDs.isEmpty ? [] : try await APISubmission.query(on: req.db)
                .filter(\.$testSetupID ~~ courseSetupIDs)
                .filter(\.$kind == APISubmission.Kind.student)
                .all()
            let workerModeSetupIDs = try await req.application.diagnostics.workerModeTestSetupIDs(
                for: courseSetupIDs,
                on: req.db
            )

            let enrolledStudentIDs = Set(
                enrolledUsers
                    .filter { $0.role == "student" }
                    .compactMap(\.id)
            )
            let loggedIn24h = enrolledUsers.reduce(into: 0) { count, user in
                guard user.role == "student" else { return }
                if let lastLoginAt = user.lastLoginAt, lastLoginAt >= windowStart {
                    count += 1
                }
            }

            let recentStudentSubmissions = recentSubmissions.filter { submission in
                guard let userID = submission.userID else { return false }
                return enrolledStudentIDs.contains(userID)
            }
            let activeAssignments24h = Set(recentStudentSubmissions.map(\.testSetupID)).count
            let pendingNow = allCourseStudentSubmissions.filter { submission in
                guard let userID = submission.userID else { return false }
                return enrolledStudentIDs.contains(userID)
                    && workerModeSetupIDs.contains(submission.testSetupID)
                    && ["pending", "assigned"].contains(submission.status)
            }.count
            let submitterIDs = Set(
                allCourseStudentSubmissions.compactMap { submission -> UUID? in
                    guard let userID = submission.userID, enrolledStudentIDs.contains(userID) else { return nil }
                    return userID
                }
            )
            let noSubmissionYet = enrolledStudentIDs.subtracting(submitterIDs).count

            metrics = [
                InstructorDashboardMetric(label: "24h Logged In", value: "\(loggedIn24h)"),
                InstructorDashboardMetric(label: "24h Submissions", value: "\(recentStudentSubmissions.count)"),
                InstructorDashboardMetric(label: "Assignments Active (24h)", value: "\(activeAssignments24h)"),
                InstructorDashboardMetric(label: "Queued Right Now", value: "\(pendingNow)"),
                InstructorDashboardMetric(label: "Students With No Submissions", value: "\(noSubmissionYet)")
            ]
        } else {
            enrolledStudents = []
            metrics = [
                InstructorDashboardMetric(label: "24h Logged In", value: "—"),
                InstructorDashboardMetric(label: "24h Submissions", value: "—"),
                InstructorDashboardMetric(label: "Assignments Active (24h)", value: "—"),
                InstructorDashboardMetric(label: "Queued Right Now", value: "—"),
                InstructorDashboardMetric(label: "Students With No Submissions", value: "—")
            ]
        }

        // Batch-fetch unique submitter counts: [testSetupID: count of distinct userIDs]
        let studentSubmissions = allSetupIDs.isEmpty ? [] : try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID ~~ allSetupIDs)
            .filter(\.$kind == APISubmission.Kind.student)
            .all()
        var submitterSets: [String: Set<UUID>] = [:]
        for sub in studentSubmissions {
            guard let uid = sub.userID else { continue }
            submitterSets[sub.testSetupID, default: []].insert(uid)
        }
        let uniqueSubmittersBySetup: [String: Int] = submitterSets.mapValues { $0.count }

        let unsortedRows: [AssignmentRow] = allSetups.map { setup in
            let assignment = assignmentBySetup[setup.id ?? ""]
            let setupID    = setup.id ?? ""
            let suiteCount: Int = {
                guard let data  = setup.manifest.data(using: .utf8),
                      let props = try? decoder.decode(TestProperties.self, from: data)
                else { return 0 }
                return props.testSuites.count
            }()

            let status: String
            if let a = assignment {
                // If isOpen is true → open; if false, check if it was ever open
                // (We don't track "was previously open" separately, so draft vs closed
                //  is distinguished by whether the title was explicitly set.)
                status = a.isOpen ? "open" : "closed"
            } else {
                status = "unpublished"
            }
            let validationStatus = assignment?.validationStatus ?? (assignment == nil ? "unpublished" : "passed")
            let validationSubmissionID = assignment?.validationSubmissionID

            return AssignmentRow(
                setupID:      setupID,
                assignmentID: assignment?.publicID,
                title:        assignment?.title,
                isOpen:       assignment?.isOpen,
                dueAt:        assignment?.dueAt.map { fmt.string(from: $0) },
                status:       status,
                sortOrder:    assignment?.sortOrder,
                validationStatus: validationStatus,
                validationSubmissionID: validationSubmissionID,
                suiteCount:   suiteCount,
                createdAt:    setup.createdAt.map { fmt.string(from: $0) } ?? "—",
                submittedStudentCount: assignment != nil ? (uniqueSubmittersBySetup[setupID] ?? 0) : nil
            )
        }

        let sortedRows = unsortedRows.sorted { lhs, rhs in
            let lhsPublished = lhs.assignmentID != nil
            let rhsPublished = rhs.assignmentID != nil
            if lhsPublished != rhsPublished {
                return lhsPublished && !rhsPublished
            }

            if lhsPublished && rhsPublished {
                switch (lhs.sortOrder, rhs.sortOrder) {
                case let (l?, r?) where l != r:
                    return l < r
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    break
                }
            }

            let lhsIndex = setupIndexByID[lhs.setupID] ?? Int.max
            let rhsIndex = setupIndexByID[rhs.setupID] ?? Int.max
            return lhsIndex < rhsIndex
        }

        // Fetch sections for the active course, sorted by sort_order.
        let allSections: [APICourseSection]
        if let activeCourseUUID = courseState.activeCourseUUID {
            allSections = try await APICourseSection.query(on: req.db)
                .filter(\.$courseID == activeCourseUUID)
                .sort(\.$sortOrder, .ascending)
                .all()
        } else {
            allSections = try await APICourseSection.query(on: req.db)
                .sort(\.$sortOrder, .ascending)
                .all()
        }

        // Build a lookup: assignment publicID → section UUID
        let sectionByPublicID: [String: UUID] = Dictionary(
            allAssignments.compactMap { a -> (String, UUID)? in
                guard let sid = a.sectionID else { return nil }
                return (a.publicID, sid)
            },
            uniquingKeysWith: { first, _ in first }
        )

        // Group sorted rows by section; rows without a matching section → ungrouped.
        var rowsBySectionID: [UUID: [AssignmentRow]] = [:]
        var ungroupedRows: [AssignmentRow] = []
        for row in sortedRows {
            if let aID = row.assignmentID, let sID = sectionByPublicID[aID] {
                rowsBySectionID[sID, default: []].append(row)
            } else {
                ungroupedRows.append(row)
            }
        }

        let sectionContexts: [CourseSectionRow] = allSections.map { section in
            let sID = section.id ?? UUID()
            return CourseSectionRow(
                sectionID: sID.uuidString,
                name: section.name,
                defaultGradingMode: section.defaultGradingMode,
                sortOrder: section.sortOrder,
                rows: rowsBySectionID[sID] ?? []
            )
        }

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
            metrics: metrics,
            sections: sectionContexts,
            ungroupedRows: ungroupedRows,
            hasSections: !allSections.isEmpty,
            hasUngrouped: !ungroupedRows.isEmpty,
            enrolledStudents: enrolledStudents,
            hasEnrolledStudents: !enrolledStudents.isEmpty,
            enrolledStudentCount: enrolledStudents.count,
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
        }
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)
        let q = (try? req.query.decode(NewQuery.self))

        let sections: [CourseSectionRow]
        if let activeCourseUUID = courseState.activeCourseUUID {
            sections = try await APICourseSection.query(on: req.db)
                .filter(\.$courseID == activeCourseUUID)
                .sort(\.$sortOrder, .ascending)
                .all()
                .map { s in CourseSectionRow(
                    sectionID: s.id?.uuidString ?? "",
                    name: s.name,
                    defaultGradingMode: s.defaultGradingMode,
                    sortOrder: s.sortOrder,
                    rows: []
                )}
        } else {
            sections = []
        }

        let ctx = NewAssignmentContext(
            currentUser: req.currentUserContext,
            assignmentName: (q?.assignmentName ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            dueAt: q?.dueAt ?? "",
            sections: sections,
            preselectedSectionID: q?.sectionID ?? "",
            notice: q?.notice,
            error: q?.error
        )
        return try await req.view.render("assignment-new", ctx)
    }

    // MARK: - POST /instructor/new/save

    @Sendable
    func saveNewAssignment(req: Request) async throws -> Response {
        let saveUser = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: saveUser)
        guard let courseID = courseState.activeCourseUUID else {
            throw Abort(.badRequest, reason: "No active course selected. Please select a course before creating an assignment.")
        }

        struct SaveBodyMany: Content {
            var assignmentName: String?
            var dueAt: String?
            var sectionID: String?
            var assignmentNotebookFile: File?
            var solutionNotebookFile: File?
            var suiteFiles: [File]?
            var suiteConfig: String?
        }
        struct SaveBodySingle: Content {
            var assignmentName: String?
            var dueAt: String?
            var sectionID: String?
            var assignmentNotebookFile: File?
            var solutionNotebookFile: File?
            var suiteFiles: File?
            var suiteConfig: String?
        }

        let bodyMany = try? req.content.decode(SaveBodyMany.self)
        let bodySingle = bodyMany == nil ? (try? req.content.decode(SaveBodySingle.self)) : nil
        guard bodyMany != nil || bodySingle != nil else {
            throw Abort(.badRequest, reason: "Invalid assignment upload payload")
        }

        let assignmentName = try multipartTextField(named: ["assignmentName"], from: req)
            ?? bodyMany?.assignmentName
            ?? bodySingle?.assignmentName
        let dueAtRaw = try multipartTextField(named: ["dueAt"], from: req)
            ?? bodyMany?.dueAt
            ?? bodySingle?.dueAt
        let sectionIDRaw = try multipartTextField(named: ["sectionID"], from: req)
            ?? bodyMany?.sectionID
            ?? bodySingle?.sectionID
        let assignmentNotebookFile = bodyMany?.assignmentNotebookFile ?? bodySingle?.assignmentNotebookFile
        let solutionNotebookFile = bodyMany?.solutionNotebookFile ?? bodySingle?.solutionNotebookFile
        let suiteFilesRaw = try multipartFiles(named: ["suiteFiles[]", "suiteFiles"], from: req)
            ?? bodyMany?.suiteFiles
            ?? (bodySingle?.suiteFiles.map { [$0] } ?? [])
        let suiteConfigRaw = try multipartTextField(named: ["suiteConfig"], from: req)
            ?? bodyMany?.suiteConfig
            ?? bodySingle?.suiteConfig

        let title = (assignmentName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let due = parseDueDate(dueAtRaw)

        guard !title.isEmpty else {
            let q = "assignmentName=&dueAt=\(urlEncode(dueAtRaw ?? ""))&error=Assignment%20name%20is%20required"
            return req.redirect(to: "/instructor/new?\(q)")
        }

        guard let assignmentNotebookFile,
              assignmentNotebookFile.data.readableBytes > 0 else {
            let q = "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(dueAtRaw ?? ""))&error=Assignment%20notebook%20(.ipynb)%20is%20required"
            return req.redirect(to: "/instructor/new?\(q)")
        }
        guard let solutionNotebookFile,
              solutionNotebookFile.data.readableBytes > 0 else {
            let q = "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(dueAtRaw ?? ""))&error=Solution%20notebook%20(.ipynb)%20is%20required"
            return req.redirect(to: "/instructor/new?\(q)")
        }
        let suiteFiles = suiteFilesRaw.filter { $0.data.readableBytes > 0 }

        let assignmentNotebookRaw = Data(assignmentNotebookFile.data.readableBytesView)
        let solutionNotebookRaw = Data(solutionNotebookFile.data.readableBytesView)
        guard (try? JSONSerialization.jsonObject(with: assignmentNotebookRaw)) != nil else {
            let q = "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(dueAtRaw ?? ""))&error=Assignment%20notebook%20is%20not%20valid%20JSON%20(.ipynb)"
            return req.redirect(to: "/instructor/new?\(q)")
        }
        guard (try? JSONSerialization.jsonObject(with: solutionNotebookRaw)) != nil else {
            let q = "assignmentName=\(urlEncode(title))&dueAt=\(urlEncode(dueAtRaw ?? ""))&error=Solution%20notebook%20is%20not%20valid%20JSON%20(.ipynb)"
            return req.redirect(to: "/instructor/new?\(q)")
        }

        let assignmentNotebook = normalizeNotebookForJupyterLite(assignmentNotebookRaw)

        let setupID = "setup_\(UUID().uuidString.lowercased().prefix(8))"
        let setupsDir = req.application.testSetupsDirectory
        let notebookFilename = notebookFilenameForStorage(
            uploadedName: assignmentNotebookFile.filename,
            fallback: "assignment.ipynb"
        )
        let notebookDir = setupsDir + "notebooks/\(setupID)/"
        try FileManager.default.createDirectory(atPath: notebookDir, withIntermediateDirectories: true)
        let notebookPath = notebookDir + notebookFilename
        let zipPath = setupsDir + "\(setupID).zip"
        try assignmentNotebook.write(to: URL(fileURLWithPath: notebookPath))
        let setupPackage = try createRunnerSetupZip(
            suiteFiles: suiteFiles,
            suiteConfigJSON: suiteConfigRaw,
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

        let manifest = try makeWorkerManifestJSON(
            testSuites: setupPackage.testSuites,
            includeMakefile: setupPackage.hasMakefile,
            gradingMode: sectionGradingMode
        )
        let setup = APITestSetup(
            id: setupID,
            manifest: manifest,
            zipPath: zipPath,
            notebookPath: notebookPath,
            courseID: courseID
        )
        try await setup.save(on: req.db)
        extractSupportFilesToSharedDirectory(
            zipPath: zipPath,
            setupID: setupID,
            testSuiteScripts: Set(setupPackage.testSuites.map { $0.script }),
            testSetupsDirectory: req.application.testSetupsDirectory
        )

        let shouldQueueValidation = !setupPackage.testSuites.isEmpty
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

        if shouldQueueValidation {
            let validationSubmissionID = try await enqueueRunnerValidationSubmission(
                req: req,
                setupID: setupID,
                solutionNotebookData: normalizeNotebookForJupyterLite(solutionNotebookRaw),
                filename: solutionNotebookFile.filename
            )
            assignment.validationSubmissionID = validationSubmissionID
            try await assignment.save(on: req.db)
            await ensureValidationRunnerAvailability(req: req)
        }
        return req.redirect(to: "/instructor")
    }

    // MARK: - POST /instructor
    // Creates a draft (isOpen: false) assignment and redirects to the validate page.

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
            throw Abort(.badRequest, reason: "Unknown testSetupID: \(body.testSetupID)")
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
            throw Abort(.badRequest, reason: "No active course selected. Please select a course before publishing an assignment.")
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
            throw Abort(.notFound)
        }

        let decoder = JSONDecoder()
        let suiteCount: Int = {
            guard let data  = setup.manifest.data(using: .utf8),
                  let props = try? decoder.decode(TestProperties.self, from: data)
            else { return 0 }
            return props.testSuites.count
        }()

        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short

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
            throw Abort(.notFound)
        }
        guard assignment.validationStatus == nil || assignment.validationStatus == "passed" else {
            throw Abort(.badRequest, reason: "Assignment cannot be opened until runner validation passes.")
        }
        assignment.isOpen = true
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
            throw Abort(.badRequest, reason: "Invalid assignment ID in reorder payload.")
        }

        let assignments = try await APIAssignment.query(on: req.db)
            .filter(\.$publicID ~~ orderedIDs)
            .all()
        let byID = Dictionary(uniqueKeysWithValues: assignments.map { ($0.publicID, $0) })
        guard byID.count == orderedIDs.count else {
            throw Abort(.badRequest, reason: "Assignment set mismatch in reorder payload.")
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
            throw Abort(.notFound)
        }

        let body = try req.content.decode(StatusBody.self)
        switch body.status {
        case "open":
            guard assignment.validationStatus == nil || assignment.validationStatus == "passed" else {
                throw Abort(.badRequest, reason: "Assignment cannot be opened until runner validation passes.")
            }
            assignment.isOpen = true
        case "closed":
            assignment.isOpen = false
        default:
            throw Abort(.badRequest, reason: "Unsupported status '\(body.status)'")
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
            throw Abort(.notFound)
        }
        assignment.isOpen = false
        try await assignment.save(on: req.db)
        return req.redirect(to: "/instructor")
    }

    // MARK: - POST /instructor/:assignmentID/delete

    @Sendable
    func deleteAssignment(req: Request) async throws -> Response {
        let idStr = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db)
        else {
            throw Abort(.notFound)
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

    // MARK: - GET /instructor/:assignmentID/edit

    @Sendable
    func editPage(req: Request) async throws -> View {
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }

        let idStr = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup      = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else {
            throw Abort(.notFound)
        }
        _ = setup // keep existence check explicit

        struct EditQuery: Content {
            var assignmentName: String?
            var dueAt: String?
            var error: String?
            var notice: String?
        }
        let q = try? req.query.decode(EditQuery.self)
        let hasKnownSolution = assignment.validationStatus == "passed"
            || assignment.validationSubmissionID != nil
        let currentFiles = currentSetupFiles(
            for: setup,
            assignmentID: idStr,
            hasValidationSolution: hasKnownSolution
        )
        let currentDueAt = dueAtLocalInputString(assignment.dueAt)
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
            existingSuiteRows: currentFiles.existingSuiteRows,
            notice: q?.notice,
            error: q?.error
        )
        return try await req.view.render("assignment-edit", ctx)
    }

}
