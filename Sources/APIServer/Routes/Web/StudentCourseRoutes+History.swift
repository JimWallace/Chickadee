// APIServer/Routes/Web/StudentCourseRoutes+History.swift
//
// Instructor-facing per-student, per-course views, scoped by the URL
// segments `/:courseCode/students/:urlToken/...`.
//
// Mirrors the student dashboard shape (one row per published assignment,
// section grouping, latest submission + best grade + badges) and adds two
// instructor actions per row: per-student retest, and an inline form to
// grant / edit / revoke a deadline extension that lets that one student
// keep submitting after the assignment-wide deadline.
//
// These handlers were moved from `AssignmentRoutes` onto
// `StudentCourseRoutes` in the Phase 2 audit refactor.

import Core
import Fluent
import Foundation
import Vapor

extension StudentCourseRoutes {

    // MARK: - GET /:courseCode/students/:urlToken/submissions

    @Sendable
    func courseStudentSubmissionsPage(req: Request) async throws -> View {
        let viewer = try req.auth.require(APIUser.self)
        let (course, student) = try await resolveCourseAndStudent(req: req)
        guard let courseID = course.id else {
            throw WebAssignmentError.notFound(resource: "Course")
        }
        // Per-course staff (TA+) may view a student's submissions — replaces the
        // old global `isInstructor` guard, which would reject a per-course TA
        // whose deployment role is student (#417 Slice E).
        try await requireCourseRole(caller: viewer, courseID: courseID, atLeast: .ta, db: req.db)

        // Phase 1: assignments + sections in parallel.  The sections query
        // only needs `courseID`, so it doesn't have to wait for assignments
        // — and the page can't render without it either way.
        //
        // Published assignments — i.e. those that have an APIAssignment row.
        // Setups without an assignment are draft/unpublished and never appear
        // in the student-facing dashboard, so they don't appear here either.
        async let assignmentsFuture = APIAssignment.query(on: req.db)
            .filter(\.$courseID == courseID)
            .all()
        async let allSectionsFuture = APICourseSection.query(on: req.db)
            .filter(\.$courseID == courseID)
            .sort(\.$sortOrder, .ascending)
            .all()
        let assignments = try await assignmentsFuture
        let allSections = try await allSectionsFuture

        let setupIDs = assignments.map(\.testSetupID)

        // Phase 2: setups + submissions + extensions + class-badges in
        // parallel.  All four depend on the assignments / setupIDs from
        // phase 1, but are independent of each other.  Pre-batching this
        // way drops the page from ~7 sequential queries to two parallel
        // groups + one dependent follow-on (the two result folds below).
        async let setupsByIDFuture = loadStudentCourseSetupsByID(req: req, setupIDs: setupIDs)
        async let submissionsFuture = loadStudentCourseSubmissions(
            req: req, student: student, setupIDs: setupIDs)
        async let extensionByAssignmentIDFuture = loadStudentCourseExtensions(
            req: req, student: student, assignments: assignments)
        async let classAchievementRowsFuture = loadStudentCourseClassAchievements(
            req: req, student: student, setupIDs: setupIDs)
        async let overrideBySetupIDFuture = loadStudentCourseOverrides(
            req: req, student: student, setupIDs: setupIDs)
        let setupsByID = try await setupsByIDFuture
        let submissions = try await submissionsFuture
        let extensionByAssignmentID = try await extensionByAssignmentIDFuture
        let classAchievementRows = try await classAchievementRowsFuture
        let overrideBySetupID = try await overrideBySetupIDFuture

        // Honor per-assignment disabled built-in awards across the page (reuses
        // the setups already loaded above, so no extra query).
        let disabledBySetup = setupsByID.mapValues { BuiltInAchievements.disabled(in: $0) }
        let propsBySetup = setupsByID.compactMapValues { $0.decodedManifest() }
        let standingsBySetup = try await standingsBySetupID(
            propsBySetupID: propsBySetup, userID: try student.requireID(), on: req.db)
        let classBadgesBySetupID = classBadgesBySetup(
            rows: classAchievementRows, setupsByID: setupsByID, disabledBySetup: disabledBySetup)

        let submissionsBySetupID = submissionsGroupedBySetupID(submissions)
        // Both folds wait until submissions resolves (they need the submission
        // IDs), so they stay serial after phase 2. The grade cells read the
        // percent; the badge path reads the row that percent came from, so a
        // badge and the grade beside it agree (#1111, #1709).
        let bestResultBySubmissionID = try await bestGradeResultBySubmissionID(
            for: submissions.compactMap(\.id),
            on: req.db
        )
        let bestPercentBySubmissionID = try await bestGradePercentBySubmissionID(
            for: submissions.compactMap(\.id),
            on: req.db
        )
        // Badges need the collection (executionTimeMs) for each assignment's
        // LATEST submission only — batch-fetch just those blobs from the
        // result_collections side table (#1173).
        let latestResultIDs = submissionsBySetupID.values.compactMap { history in
            history.first?.id.flatMap { bestResultBySubmissionID[$0]?.id }
        }
        let latestBlobs = try await collectionJSONByResultID(for: latestResultIDs, on: req.db)
        let collectionByResultID = latestBlobs.compactMapValues(decodedCollection(from:))

        let fmt = waterlooDateTimeFormatter()
        let sortedAssignments = sortedByAssignmentDisplayOrder(assignments, setupsByID: setupsByID)

        let rowContext = StudentAssignmentRowContext(
            courseCode: course.urlKey,
            urlToken: try student.requireURLToken(),
            bestResultBySubmissionID: bestResultBySubmissionID,
            collectionByResultID: collectionByResultID,
            bestPercentBySubmissionID: bestPercentBySubmissionID,
            student: student,
            fmt: fmt,
            disabledBySetup: disabledBySetup,
            propsBySetup: propsBySetup,
            standingsBySetup: standingsBySetup
        )
        let rows = sortedAssignments.map { assignment in
            buildStudentAssignmentRow(
                assignment: assignment,
                history: submissionsBySetupID[assignment.testSetupID] ?? [],
                classBadges: classBadgesBySetupID[assignment.testSetupID] ?? [],
                activeExtension: assignment.id.flatMap { extensionByAssignmentID[$0] },
                activeOverride: overrideBySetupID[assignment.testSetupID],
                context: rowContext
            )
        }

        let (sectionContexts, ungroupedRows) = groupStudentCourseRowsBySection(
            rows: rows,
            assignments: assignments,
            allSections: allSections
        )

        return try await req.view.render(
            "course-student-submissions",
            CourseStudentSubmissionsContext(
                currentUser: req.currentUserContext,
                studentName: student.displayName ?? student.username,
                studentUsername: student.username,
                courseCode: course.code,
                courseName: "\(course.code) — \(course.name)",
                backURL: "/instructor",
                sections: sectionContexts,
                ungroupedRows: ungroupedRows,
                hasSections: !allSections.isEmpty,
                hasUngrouped: !ungroupedRows.isEmpty,
                ungroupedRowsContext: StudentAssignmentRowsContext(rows: ungroupedRows)
            )
        )
    }

    // MARK: - courseStudentSubmissionsPage helpers

    fileprivate func loadStudentCourseSetupsByID(
        req: Request, setupIDs: [String]
    ) async throws -> [String: APITestSetup] {
        guard !setupIDs.isEmpty else { return [:] }
        let setups = try await APITestSetup.query(on: req.db)
            .filter(\.$id ~~ Set(setupIDs))
            .all()
        return Dictionary(
            setups.compactMap { setup in setup.id.map { ($0, setup) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    fileprivate func loadStudentCourseSubmissions(
        req: Request, student: APIUser, setupIDs: [String]
    ) async throws -> [APISubmission] {
        guard let studentUUID = student.id, !setupIDs.isEmpty else { return [] }
        return try await APISubmission.query(on: req.db)
            .filter(\.$userID == studentUUID)
            .filter(\.$kind == APISubmission.Kind.student)
            .filter(\.$testSetupID ~~ Set(setupIDs))
            .sort(\.$submittedAt, .descending)
            .all()
    }

    fileprivate func submissionsGroupedBySetupID(
        _ submissions: [APISubmission]
    ) -> [String: [APISubmission]] {
        var submissionsBySetupID: [String: [APISubmission]] = [:]
        for submission in submissions {
            submissionsBySetupID[submission.testSetupID, default: []].append(submission)
        }
        return submissionsBySetupID
    }

    fileprivate func loadStudentCourseExtensions(
        req: Request, student: APIUser, assignments: [APIAssignment]
    ) async throws -> [UUID: APIAssignmentExtension] {
        guard let studentUUID = student.id, !assignments.isEmpty else { return [:] }
        let assignmentUUIDs = assignments.compactMap(\.id)
        let extensions = try await APIAssignmentExtension.query(on: req.db)
            .filter(\.$assignmentID ~~ Set(assignmentUUIDs))
            .filter(\.$userID == studentUUID)
            .all()
        var extensionByAssignmentID: [UUID: APIAssignmentExtension] = [:]
        for row in extensions {
            extensionByAssignmentID[row.assignmentID] = row
        }
        return extensionByAssignmentID
    }

    /// Maps the student's class-achievement rows to display badges once the
    /// setups (and their manifests) are loaded — after phase 2, so
    /// manifest-authored records (custom IDs / renamed built-ins) resolve
    /// instead of being dropped by the registry-only lookup (audit A6).
    fileprivate func classBadgesBySetup(
        rows: [APIClassAchievement],
        setupsByID: [String: APITestSetup],
        disabledBySetup: [String: Set<String>]
    ) -> [String: [AchievementBadge]] {
        let achievementsBySetup = setupsByID.mapValues { $0.decodedManifest()?.achievements ?? [] }
        var badges: [String: [AchievementBadge]] = [:]
        for achievement in rows {
            let setupID = achievement.testSetupID
            if let badge = AchievementBadge.forClassAchievement(
                achievement.achievementID,
                manifestAchievements: achievementsBySetup[setupID] ?? [],
                disabled: disabledBySetup[setupID] ?? [])
            {
                badges[setupID, default: []].append(badge)
            }
        }
        return badges
    }

    /// The raw class-achievement rows this student holds; badge mapping happens
    /// at the call site once the setups (and their manifests) are loaded, so
    /// manifest-authored records resolve (audit A6).
    fileprivate func loadStudentCourseClassAchievements(
        req: Request, student: APIUser, setupIDs: [String]
    ) async throws -> [APIClassAchievement] {
        guard let studentUUID = student.id, !setupIDs.isEmpty else { return [] }
        return try await APIClassAchievement.query(on: req.db)
            .filter(\.$userID == studentUUID)
            .filter(\.$testSetupID ~~ Set(setupIDs))
            .all()
    }

    fileprivate func loadStudentCourseOverrides(
        req: Request, student: APIUser, setupIDs: [String]
    ) async throws -> [String: APIGradeOverride] {
        guard let studentUUID = student.id, !setupIDs.isEmpty else { return [:] }
        let overrides = try await APIGradeOverride.query(on: req.db)
            .filter(\.$testSetupID ~~ Set(setupIDs))
            .filter(\.$userID == studentUUID)
            .all()
        var overrideBySetupID: [String: APIGradeOverride] = [:]
        for row in overrides {
            overrideBySetupID[row.testSetupID] = row
        }
        return overrideBySetupID
    }

    /// Sort comparator matches the student dashboard (`WebRoutes.swift`):
    /// sortOrder → createdAt → id.
    fileprivate func groupStudentCourseRowsBySection(
        rows: [StudentAssignmentRow],
        assignments: [APIAssignment],
        allSections: [APICourseSection]
    ) -> (sections: [StudentAssignmentSectionContext], ungrouped: [StudentAssignmentRow]) {
        let sectionByAssignmentID: [String: UUID] = Dictionary(
            assignments.compactMap { a -> (String, UUID)? in
                guard let sid = a.sectionID else { return nil }
                return (a.publicID, sid)
            },
            uniquingKeysWith: { first, _ in first }
        )
        // Shared section-grouping fold (#1118); empty sections stay hidden.
        let grouped = groupRowsBySection(
            rows: rows, sections: allSections, includeEmptySections: false,
            sectionIDForRow: { sectionByAssignmentID[$0.assignmentID] },
            makeSection: { section, sectionRows in
                StudentAssignmentSectionContext(
                    sectionID: (section.id ?? UUID()).uuidString,
                    name: section.name,
                    rows: sectionRows
                )
            })
        return (grouped.sections, grouped.ungrouped)
    }

    // MARK: - GET /:courseCode/students/:urlToken/assignments/:assignmentID/history

    @Sendable
    func studentAssignmentHistoryPage(req: Request) async throws -> View {
        let action = try await resolveStudentAssignmentAction(
            req: req, action: "view student submission history")
        let (course, student, assignment) = (action.course, action.student, action.assignment)
        let assignmentIDRaw = assignment.publicID

        let submissions = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == assignment.testSetupID)
            .filter(\.$userID == action.studentID)
            .filter(\.$kind == APISubmission.Kind.student)
            .sort(\.$submittedAt, .descending)
            .all()
        // "Highest grade wins" across ALL result sources — matches the
        // roster/dashboard surfaces this page is reached from (#1111; it
        // used to show the worker-preferred grade instead).
        let bestPercentBySubmissionID = try await bestGradePercentBySubmissionID(
            for: submissions.compactMap(\.id),
            on: req.db
        )

        let fmt = waterlooDateTimeFormatter()
        let rows = assignmentSubmissionHistoryRows(
            submissions: submissions,
            bestPercentBySubmissionID: bestPercentBySubmissionID,
            fmt: fmt)

        let studentToken = try student.requireURLToken()
        let backURL = StudentCoursePaths.submissions(
            courseCode: course.urlKey,
            urlToken: studentToken
        )
        let historyPath = StudentCoursePaths.assignmentHistory(
            courseCode: course.urlKey,
            urlToken: studentToken,
            assignmentID: assignmentIDRaw
        )

        let studentName = accountIdentityName(
            displayName: student.displayName, preferredName: student.preferredName, username: student.username)
        return try await req.view.render(
            "student-assignment-history",
            StudentAssignmentHistoryContext(
                currentUser: req.currentUserContext,
                studentName: studentName,
                studentUsername: accountIdentitySecondary(identityName: studentName, username: student.username),
                assignmentID: assignmentIDRaw,
                assignmentTitle: assignment.title,
                backURL: backURL,
                backLabel: "Back to student",
                showsDiff: false,
                historyPath: historyPath,
                rows: rows
            )
        )
    }

    // MARK: - POST /:courseCode/students/:urlToken/assignments/:assignmentID/retest

    @Sendable
    func retestStudentAssignment(req: Request) async throws -> Response {
        let action = try await resolveStudentAssignmentAction(
            req: req, action: "retest student submissions", writeFloor: .ta)
        let (actor, student, assignment) = (action.actor, action.student, action.assignment)
        let assignmentIDRaw = assignment.publicID

        let count = try await retestStudentSubmissionsForSetup(
            setupID: assignment.testSetupID,
            studentUserID: action.studentID,
            triggeredBy: actor.id,
            on: req.db,
            force: true
        )

        req.logger.info(
            "retest_student_triggered assignment=\(assignmentIDRaw) student=\(student.username) count=\(count) by=\(actor.id?.uuidString ?? "nil")"
        )
        await AuditLogger.record(
            action: .submissionRetestForStudent,
            targetType: .assignment,
            targetID: assignment.id?.uuidString,
            metadata: [
                "assignment": assignmentIDRaw,
                "student_username": student.username,
                "submission_count": String(count),
            ],
            on: req
        )

        return try redirectToStudentSubmissions(req: req, course: action.course, student: student)
    }

    // MARK: - POST /:courseCode/students/:urlToken/assignments/:assignmentID/reset-notebook

    /// Resets one student's working-copy notebook for one assignment back to
    /// the published starter.  Past submissions are untouched — this only
    /// overwrites the in-progress JupyterLite copy (e.g. when a student has
    /// corrupted their notebook and can't recover).  Mirrors the per-assignment
    /// `resetStudentNotebook` action, scoped to this course-student page so the
    /// redirect lands back here.
    @Sendable
    func resetStudentAssignmentNotebook(req: Request) async throws -> Response {
        let action = try await resolveStudentAssignmentAction(
            req: req, action: "reset student notebooks", writeFloor: .ta)
        let (actor, student, assignment) = (action.actor, action.student, action.assignment)
        let assignmentIDRaw = assignment.publicID
        guard let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db) else {
            throw WebAssignmentError.notFound(resource: "Test setup")
        }

        let starter: Data
        do {
            starter = try await req.application.notebookBytesCache.notebookData(
                for: NotebookSourceRef(setup))
        } catch {
            throw WebAssignmentError.invalidParameter(
                name: "setup",
                reason: "Test setup has no starter notebook to reset to."
            )
        }

        _ = try await overwriteUserNotebookWithPersonalizedStarter(
            setup: setup,
            userID: action.studentID,
            starter: starter,
            on: req.db, application: req.application, logger: req.logger
        )

        req.logger.info(
            "student_notebook_reset assignment=\(assignmentIDRaw) student=\(student.username) by=\(actor.id?.uuidString ?? "nil")"
        )

        return try redirectToStudentSubmissions(req: req, course: action.course, student: student)
    }

    // MARK: - POST /:courseCode/students/:urlToken/assignments/:assignmentID/extension

    @Sendable
    func saveStudentAssignmentExtension(req: Request) async throws -> Response {
        struct ExtensionBody: Content {
            var extendedDueAt: String?
            var note: String?
        }

        let action = try await resolveStudentAssignmentAction(
            req: req, action: "grant deadline extensions", writeFloor: .ta)
        let (actor, student) = (action.actor, action.student)
        let assignmentIDRaw = action.assignment.publicID
        let studentUUID = action.studentID
        guard let assignmentUUID = action.assignment.id else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(assignmentIDRaw)'")
        }

        let body = try req.content.decode(ExtensionBody.self)
        let rawDate = (body.extendedDueAt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawDate.isEmpty,
            let newDueAt = parseDueDate(rawDate)
        else {
            throw WebAssignmentError.invalidParameter(
                name: "extendedDueAt",
                reason: "Provide a valid date and time in the form's input."
            )
        }
        let trimmedNote = body.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = (trimmedNote?.isEmpty == false) ? trimmedNote : nil

        let existing = try await APIAssignmentExtension.query(on: req.db)
            .filter(\.$assignmentID == assignmentUUID)
            .filter(\.$userID == studentUUID)
            .first()

        if let existing {
            existing.extendedDueAt = newDueAt
            existing.note = note
            existing.grantedByUserID = actor.id
            try await existing.save(on: req.db)
        } else {
            let row = APIAssignmentExtension(
                assignmentID: assignmentUUID,
                userID: studentUUID,
                extendedDueAt: newDueAt,
                note: note,
                grantedByUserID: actor.id
            )
            try await row.save(on: req.db)
        }

        await AuditLogger.record(
            action: .extensionGranted,
            targetType: .assignment,
            targetID: assignmentUUID.uuidString,
            metadata: [
                "assignment": assignmentIDRaw,
                "student_username": student.username,
                "extended_due_at": iso8601String(newDueAt),
            ],
            on: req
        )

        return try redirectToStudentSubmissions(req: req, course: action.course, student: student)
    }

    // MARK: - POST /:courseCode/students/:urlToken/assignments/:assignmentID/extension/delete

    @Sendable
    func deleteStudentAssignmentExtension(req: Request) async throws -> Response {
        let action = try await resolveStudentAssignmentAction(
            req: req, action: "revoke deadline extensions", writeFloor: .ta)
        let student = action.student
        let assignmentIDRaw = action.assignment.publicID
        let studentUUID = action.studentID
        guard let assignmentUUID = action.assignment.id else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(assignmentIDRaw)'")
        }

        let existing = try await APIAssignmentExtension.query(on: req.db)
            .filter(\.$assignmentID == assignmentUUID)
            .filter(\.$userID == studentUUID)
            .first()
        if let existing {
            try await existing.delete(on: req.db)
            await AuditLogger.record(
                action: .extensionRevoked,
                targetType: .assignment,
                targetID: assignmentUUID.uuidString,
                metadata: [
                    "assignment": assignmentIDRaw,
                    "student_username": student.username,
                ],
                on: req
            )
        }

        return try redirectToStudentSubmissions(req: req, course: action.course, student: student)
    }

    // MARK: - POST /:courseCode/students/:urlToken/assignments/:assignmentID/grade-override

    @Sendable
    func saveStudentAssignmentGradeOverride(req: Request) async throws -> Response {
        struct OverrideBody: Content {
            var overridePercent: Int?
            var note: String?
        }

        let action = try await resolveStudentAssignmentAction(
            req: req, action: "override grades", writeFloor: .ta)
        let (actor, student, assignment) = (action.actor, action.student, action.assignment)
        let assignmentIDRaw = assignment.publicID
        let studentUUID = action.studentID
        let testSetupID = assignment.testSetupID

        let body = try req.content.decode(OverrideBody.self)
        guard let percent = body.overridePercent, (0...100).contains(percent) else {
            throw WebAssignmentError.invalidParameter(
                name: "overridePercent",
                reason: "Provide a whole-number percent between 0 and 100."
            )
        }
        let trimmedNote = body.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = (trimmedNote?.isEmpty == false) ? trimmedNote : nil

        try await applyGradeOverride(
            testSetupID: testSetupID,
            studentUserID: studentUUID,
            percent: percent,
            note: note,
            grantedByUserID: actor.id,
            on: req.db
        )

        await AuditLogger.record(
            action: .gradeOverrideSet,
            targetType: .assignment,
            targetID: assignment.id?.uuidString,
            metadata: [
                "assignment": assignmentIDRaw,
                "student_username": student.username,
                "override_percent": String(percent),
            ],
            on: req
        )

        return try redirectToStudentSubmissions(req: req, course: action.course, student: student)
    }

    // MARK: - POST /:courseCode/students/:urlToken/assignments/:assignmentID/grade-override/delete

    @Sendable
    func deleteStudentAssignmentGradeOverride(req: Request) async throws -> Response {
        let action = try await resolveStudentAssignmentAction(
            req: req, action: "clear grade overrides", writeFloor: .ta)
        let (student, assignment) = (action.student, action.assignment)
        let assignmentIDRaw = assignment.publicID
        let studentUUID = action.studentID
        let testSetupID = assignment.testSetupID

        if try await clearGradeOverride(
            testSetupID: testSetupID, studentUserID: studentUUID, on: req.db)
        {
            await AuditLogger.record(
                action: .gradeOverrideCleared,
                targetType: .assignment,
                targetID: assignment.id?.uuidString,
                metadata: [
                    "assignment": assignmentIDRaw,
                    "student_username": student.username,
                ],
                on: req
            )
        }

        return try redirectToStudentSubmissions(req: req, course: action.course, student: student)
    }
}

// MARK: - Private helpers

extension StudentCourseRoutes {
    /// Resolves `(course, student)` from `:courseCode` + `:urlToken`.
    /// Throws `WebAssignmentError.notFound` if either side is missing OR if
    /// the student is not currently enrolled in the course (matches the
    /// instructor dashboard's clickability rule).  Enrollment, not role,
    /// gates this — an instructor enrolled for testing should be reachable
    /// via the same path the dashboard exposes for them.  The url token
    /// is opaque (8-char lowercase alphanumeric) so usernames don't leak
    /// into request logs (#556); on miss the response body is the same
    /// generic "student not found" page either way, so brute-force token
    /// enumeration learns nothing.
    fileprivate func resolveCourseAndStudent(req: Request) async throws -> (APICourse, APIUser) {
        guard let courseCodeRaw = req.parameters.get("courseCode"),
            let urlTokenRaw = req.parameters.get("urlToken")
        else {
            throw WebAssignmentError.notFound(resource: "Course or student")
        }
        let course = try await findActiveCourse(
            byKey: courseCodeRaw, viewer: req.auth.get(APIUser.self)?.id, on: req.db)
        guard let course, let courseUUID = course.id else {
            throw WebAssignmentError.notFound(resource: "Course '\(courseCodeRaw)'")
        }
        guard
            let student = try await APIUser.query(on: req.db)
                .filter(\.$urlToken == urlTokenRaw)
                .first(),
            let studentID = student.id
        else {
            throw WebAssignmentError.notFound(resource: "Student")
        }
        let isEnrolled =
            try await APICourseEnrollment.query(on: req.db)
            .filter(\.$course.$id == courseUUID)
            .filter(\.$userID == studentID)
            .count() > 0
        guard isEnrolled else {
            throw WebAssignmentError.notFound(resource: "Enrolled student")
        }
        return (course, student)
    }

    /// Everything the per-student assignment handlers resolve before doing
    /// their real work: the authenticated instructor, the `(course, student)`
    /// pair from `:courseCode` + `:urlToken`, and the `:assignmentID`
    /// assignment verified to belong to that course.
    fileprivate struct StudentAssignmentActionContext {
        let actor: APIUser
        let course: APICourse
        let student: APIUser
        let studentID: UUID
        let assignment: APIAssignment
    }

    /// Shared resolve preamble for the seven per-student assignment handlers
    /// (history page, retest, notebook reset, extension save/delete, grade
    /// override save/delete).
    ///
    /// Note on the role check: these routes are registered under the
    /// `/instructor` group's `ActiveCourseStaffMiddleware` (routes.swift),
    /// which gates on instructor authority in the caller's *active* course. The
    /// `isInstructor` guard here is defense-in-depth in case the route grouping
    /// ever changes. `action` carries each handler's original forbidden-message
    /// wording.
    ///
    /// Authorization is per-course (#417 Slice E): every caller must be staff
    /// (TA or instructor) in the assignment's **own** course — `requireCourseRole
    /// (atLeast: .ta)`, which replaces the old global `isInstructor` guard that
    /// would wrongly reject a per-course TA whose deployment role is student.
    /// This covers the read-only history page.
    ///
    /// `writeFloor`, when non-nil, additionally authorizes a *write* on that
    /// course via `requireCourseWriteAccess` (archived-course block + the
    /// action's minimum role): the per-student grading/accommodation actions
    /// (retest / reset / grade-override / extension grant / extension revoke)
    /// all pass `.ta`. A per-student extension is an individual accommodation,
    /// not a change to the assignment-wide deadline — the assignment *lifecycle*
    /// (open/close/set due date) stays `.instructor` on its own routes. The
    /// read-only history page leaves it nil so archived courses stay auditable.
    ///
    /// Error semantics match the guard chain each handler previously
    /// inlined: `notFound("Assignment '<id>'")` when the assignment is
    /// missing, belongs to a different course, or (unreachable for a
    /// DB-loaded model) the student row has no id.
    fileprivate func resolveStudentAssignmentAction(
        req: Request, action: String, writeFloor: CourseRole? = nil
    ) async throws -> StudentAssignmentActionContext {
        let actor = try req.auth.require(APIUser.self)
        let (course, student) = try await resolveCourseAndStudent(req: req)
        let assignment = try await loadAssignment(req)
        guard assignment.courseID == course.id, let studentID = student.id else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(assignment.publicID)'")
        }
        // Per-course staff gate (TA+ in THIS course; admin bypass).
        try await requireCourseRole(
            caller: actor, courseID: assignment.courseID, atLeast: .ta, db: req.db)
        if let writeFloor {
            try await requireCourseWriteAccess(
                caller: actor, courseID: assignment.courseID, atLeast: writeFloor, db: req.db)
        }
        return StudentAssignmentActionContext(
            actor: actor, course: course, student: student,
            studentID: studentID, assignment: assignment)
    }

    /// Shared redirect epilogue: back to this student's per-course
    /// submissions page.
    fileprivate func redirectToStudentSubmissions(
        req: Request, course: APICourse, student: APIUser
    ) throws -> Response {
        req.redirect(
            to: StudentCoursePaths.submissions(
                courseCode: course.urlKey,
                urlToken: try student.requireURLToken()
            )
        )
    }

    /// Bundles the per-table inputs that don't vary across rows.  Keeps
    /// `buildStudentAssignmentRow` to a handful of parameters even with
    /// many logical inputs.  `urlToken` is the student's opaque URL token
    /// (#556) — used to build per-student action URLs without leaking
    /// the username into request logs.
    fileprivate struct StudentAssignmentRowContext {
        let courseCode: String
        let urlToken: String
        let bestResultBySubmissionID: [String: APIResult]
        /// Decoded collection per latest-submission best-grade result id —
        /// pre-fetched from the result_collections side table (#1173) for
        /// the badge path.
        let collectionByResultID: [String: TestOutcomeCollection]
        /// "Highest grade wins" percent per submission (#1111) — feeds the
        /// grade cells; `bestResultBySubmissionID` feeds the badges with the same rows.
        let bestPercentBySubmissionID: [String: Int]
        let student: APIUser
        let fmt: DateFormatter
        /// `[setupID: disabled built-in award ids]` — the same map for every row.
        let disabledBySetup: [String: Set<String>]
        /// `[setupID: decoded manifest]` — same map every row; an absent
        /// setup falls back to the built-in registry.
        let propsBySetup: [String: TestProperties]
        /// `[setupID: round-robin place]`, only for standings activities.
        let standingsBySetup: [String: (standing: Int, matchesWon: Int)]
    }

    fileprivate func buildStudentAssignmentRow(
        assignment: APIAssignment,
        history: [APISubmission],
        classBadges: [AchievementBadge],
        activeExtension: APIAssignmentExtension?,
        activeOverride: APIGradeOverride?,
        context: StudentAssignmentRowContext
    ) -> StudentAssignmentRow {
        let courseCode = context.courseCode
        let urlToken = context.urlToken
        let bestResultBySubmissionID = context.bestResultBySubmissionID
        let fmt = context.fmt
        let latest = history.first
        // Highest grade across the whole history, from the shared
        // highest-grade-wins map (#1111).
        let bestGradePercent: Int? =
            history
            .compactMap { submission in
                submission.id.flatMap { context.bestPercentBySubmissionID[$0] }
            }
            .max()

        let disabledHere = context.disabledBySetup[assignment.testSetupID] ?? []
        var badges = submissionBadges(
            history: history,
            bestResultBySubmissionID: bestResultBySubmissionID,
            collectionByResultID: context.collectionByResultID,
            props: context.propsBySetup[assignment.testSetupID],
            standings: context.standingsBySetup[assignment.testSetupID]
        ).filter { !disabledHere.contains($0.id) }
        badges.append(contentsOf: classBadges)

        let dueAtText = assignment.dueAt.map { fmt.string(from: $0) }
        let extensionDueAt = activeExtension?.extendedDueAt
        let effectiveDueAtText: String? = {
            guard let extDate = extensionDueAt else { return nil }
            return fmt.string(from: extDate)
        }()
        let formInput = dueAtLocalInputString(extensionDueAt ?? assignment.dueAt)

        return StudentAssignmentRow(
            assignmentID: assignment.publicID,
            title: assignment.title,
            // Student-facing: Preview is indistinguishable from closed.
            status: assignment.visibility == .preview ? "closed" : assignment.visibility.rawValue,
            isOpen: assignment.isOpen,
            dueAtText: dueAtText,
            effectiveDueAtText: effectiveDueAtText,
            hasExtension: activeExtension != nil,
            extensionFormInput: formInput,
            extensionSavePath: StudentCoursePaths.extensionSave(
                courseCode: courseCode,
                urlToken: urlToken,
                assignmentID: assignment.publicID
            ),
            extensionDeletePath: StudentCoursePaths.extensionDelete(
                courseCode: courseCode,
                urlToken: urlToken,
                assignmentID: assignment.publicID
            ),
            retestPath: StudentCoursePaths.retest(
                courseCode: courseCode,
                urlToken: urlToken,
                assignmentID: assignment.publicID
            ),
            resetPath: StudentCoursePaths.reset(
                courseCode: courseCode,
                urlToken: urlToken,
                assignmentID: assignment.publicID
            ),
            historyURL: StudentCoursePaths.assignmentHistory(
                courseCode: courseCode,
                urlToken: urlToken,
                assignmentID: assignment.publicID
            ),
            latest: LatestSubmissionCell(
                count: history.count,
                latestSubmissionID: latest?.id,
                latestSubmittedAtText: latest?.submittedAt.map { fmt.string(from: $0) },
                bestPercent: bestGradePercent,
                overridePercent: activeOverride?.overridePercent),
            gradeOverridePercent: activeOverride?.overridePercent ?? bestGradePercent ?? 0,
            gradeOverrideSavePath: StudentCoursePaths.gradeOverrideSave(
                courseCode: courseCode,
                urlToken: urlToken,
                assignmentID: assignment.publicID
            ),
            gradeOverrideClearPath: StudentCoursePaths.gradeOverrideClear(
                courseCode: courseCode,
                urlToken: urlToken,
                assignmentID: assignment.publicID
            ),
            badges: badges
        )
    }

    /// The badges the latest submission earns by itself (the same call the
    /// submission page makes, #2020).  Class-wide badges are appended by the
    /// caller.
    fileprivate func submissionBadges(
        history: [APISubmission],
        bestResultBySubmissionID: [String: APIResult],
        collectionByResultID: [String: TestOutcomeCollection],
        props: TestProperties?,
        standings: (standing: Int, matchesWon: Int)?
    ) -> [AchievementBadge] {
        guard let latestSubmission = history.first,
            let latestSubID = latestSubmission.id,
            let result = bestResultBySubmissionID[latestSubID],
            let resultID = result.id,
            let collection = collectionByResultID[resultID],
            let gradePct = gradePercent(from: collection)
        else {
            return []
        }
        let latestAttempt = latestSubmission.attemptNumber ?? 1
        let priorSub = history.first(where: { $0.attemptNumber == latestAttempt - 1 })
        let priorPct: Int? = priorSub.flatMap { ps in
            guard let psID = ps.id, let pr = bestResultBySubmissionID[psID] else {
                return nil
            }
            return pr.gradePercentValue
        }
        return badgesEarnedBySubmission(
            BadgeContext(
                attemptNumber: latestAttempt,
                gradePercent: gradePct,
                executionTimeMs: collection.executionTimeMs,
                priorGradePercent: priorPct,
                outcomes: collection.outcomes,
                testNameAliases: props?.testNameAliases() ?? [:]
            ),
            props: props,
            standings: standings)
    }
}
