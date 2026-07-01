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
        // groups + one dependent follow-on (preferredResults below).
        async let setupsByIDFuture = loadStudentCourseSetupsByID(req: req, setupIDs: setupIDs)
        async let submissionsFuture = loadStudentCourseSubmissions(
            req: req, student: student, setupIDs: setupIDs)
        async let extensionByAssignmentIDFuture = loadStudentCourseExtensions(
            req: req, student: student, assignments: assignments)
        async let classBadgesBySetupIDFuture = loadStudentCourseClassBadges(
            req: req, student: student, setupIDs: setupIDs)
        async let overrideBySetupIDFuture = loadStudentCourseOverrides(
            req: req, student: student, setupIDs: setupIDs)
        let setupsByID = try await setupsByIDFuture
        let submissions = try await submissionsFuture
        let extensionByAssignmentID = try await extensionByAssignmentIDFuture
        let classBadgesBySetupIDRaw = try await classBadgesBySetupIDFuture
        let overrideBySetupID = try await overrideBySetupIDFuture

        // Honor per-assignment disabled built-in awards across the page (reuses
        // the setups already loaded above, so no extra query).
        let disabledBySetup = setupsByID.mapValues { BuiltInAchievements.disabled(in: $0) }
        let perSubBySetup = setupsByID.compactMapValues { BuiltInAchievements.manifestPerSubmission(in: $0) }
        let classBadgesBySetupID = classBadgesBySetupIDRaw.reduce(
            into: [String: [AchievementBadge]]()
        ) { acc, entry in
            let disabled = disabledBySetup[entry.key] ?? []
            let kept = disabled.isEmpty ? entry.value : entry.value.filter { !disabled.contains($0.id) }
            if !kept.isEmpty { acc[entry.key] = kept }
        }

        let submissionsBySetupID = submissionsGroupedBySetupID(submissions)
        // preferredResults must wait until submissions resolves (it needs
        // the submission IDs), so it stays serial after phase 2.
        let preferredResultBySubmissionID = try await preferredResultsBySubmissionID(
            for: submissions.compactMap(\.id),
            on: req.db
        )
        // Grade cells use the shared "highest grade wins" fold across ALL
        // result sources (#1111); preferredResults stays for the badge path.
        let bestPercentBySubmissionID = try await bestGradePercentBySubmissionID(
            for: submissions.compactMap(\.id),
            on: req.db
        )

        let fmt = waterlooDateTimeFormatter()
        let sortedAssignments = sortedStudentCourseAssignments(assignments, setupsByID: setupsByID)

        let rowContext = StudentAssignmentRowContext(
            courseCode: course.code,
            urlToken: try student.requireURLToken(),
            preferredResultBySubmissionID: preferredResultBySubmissionID,
            bestPercentBySubmissionID: bestPercentBySubmissionID,
            student: student,
            fmt: fmt,
            disabledBySetup: disabledBySetup,
            perSubBySetup: perSubBySetup
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
                hasUngrouped: !ungroupedRows.isEmpty
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

    fileprivate func loadStudentCourseClassBadges(
        req: Request, student: APIUser, setupIDs: [String]
    ) async throws -> [String: [AchievementBadge]] {
        guard let studentUUID = student.id, !setupIDs.isEmpty else { return [:] }
        let classAchievements = try await APIClassAchievement.query(on: req.db)
            .filter(\.$userID == studentUUID)
            .filter(\.$testSetupID ~~ Set(setupIDs))
            .all()
        var classBadgesBySetupID: [String: [AchievementBadge]] = [:]
        for achievement in classAchievements {
            if let badge = AchievementBadge.forClassAchievement(achievement.achievementID) {
                classBadgesBySetupID[achievement.testSetupID, default: []].append(badge)
            }
        }
        return classBadgesBySetupID
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
    fileprivate func sortedStudentCourseAssignments(
        _ assignments: [APIAssignment],
        setupsByID: [String: APITestSetup]
    ) -> [APIAssignment] {
        assignments.sorted { lhs, rhs in
            let lhsOrder = lhs.sortOrder
            let rhsOrder = rhs.sortOrder
            if let l = lhsOrder, let r = rhsOrder, l != r { return l < r }
            let lhsCreated = setupsByID[lhs.testSetupID]?.createdAt ?? .distantPast
            let rhsCreated = setupsByID[rhs.testSetupID]?.createdAt ?? .distantPast
            if lhsCreated != rhsCreated { return lhsCreated > rhsCreated }
            return lhs.testSetupID < rhs.testSetupID
        }
    }

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
        var rowsBySectionID: [UUID: [StudentAssignmentRow]] = [:]
        var ungroupedRows: [StudentAssignmentRow] = []
        for row in rows {
            if let sID = sectionByAssignmentID[row.assignmentID] {
                rowsBySectionID[sID, default: []].append(row)
            } else {
                ungroupedRows.append(row)
            }
        }
        let sectionContexts: [StudentAssignmentSectionContext] = allSections.compactMap { section in
            guard let sID = section.id else { return nil }
            let sectionRows = rowsBySectionID[sID] ?? []
            guard !sectionRows.isEmpty else { return nil }
            return StudentAssignmentSectionContext(
                sectionID: sID.uuidString,
                name: section.name,
                rows: sectionRows
            )
        }
        return (sectionContexts, ungroupedRows)
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
        let rows = submissions.map { submission -> AssignmentSubmissionHistoryRow in
            let subID = submission.id ?? ""
            let gradeText: String
            if let pct = bestPercentBySubmissionID[subID] {
                gradeText = "\(pct)%"
            } else {
                gradeText = "—"
            }
            return AssignmentSubmissionHistoryRow(
                submissionID: subID,
                attemptNumber: submission.attemptNumber ?? 1,
                status: submission.status,
                submittedAt: submission.submittedAt.map { fmt.string(from: $0) } ?? "—",
                gradeText: gradeText
            )
        }

        let studentToken = try student.requireURLToken()
        let backURL = StudentCoursePaths.submissions(
            courseCode: course.code,
            urlToken: studentToken
        )
        let historyPath = StudentCoursePaths.assignmentHistory(
            courseCode: course.code,
            urlToken: studentToken,
            assignmentID: assignmentIDRaw
        )

        return try await req.view.render(
            "student-assignment-history",
            StudentAssignmentHistoryContext(
                currentUser: req.currentUserContext,
                studentName: student.displayName ?? student.username,
                studentUsername: student.username,
                courseCode: course.code,
                assignmentID: assignmentIDRaw,
                assignmentTitle: assignment.title,
                backURL: backURL,
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
            starter = try notebookData(for: setup)
        } catch {
            throw WebAssignmentError.invalidParameter(
                name: "setup",
                reason: "Test setup has no starter notebook to reset to."
            )
        }

        _ = try await ensureUserNotebookWorkingCopy(
            req: req,
            setupID: setup.id ?? assignment.testSetupID,
            userID: action.studentID,
            fallbackSetup: setup,
            overwriteWith: starter
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
            req: req, action: "grant deadline extensions", writeFloor: .instructor)
        let (actor, student) = (action.actor, action.student)
        let assignmentIDRaw = action.assignment.publicID
        let studentUUID = action.studentID
        guard let assignmentUUID = action.assignment.id else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(assignmentIDRaw)'")
        }

        let body = try req.content.decode(ExtensionBody.self)
        let rawDate = (body.extendedDueAt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawDate.isEmpty,
            let newDueAt = parseLocalInputDate(rawDate)
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
                "extended_due_at": ISO8601DateFormatter().string(from: newDueAt),
            ],
            on: req
        )

        return try redirectToStudentSubmissions(req: req, course: action.course, student: student)
    }

    // MARK: - POST /:courseCode/students/:urlToken/assignments/:assignmentID/extension/delete

    @Sendable
    func deleteStudentAssignmentExtension(req: Request) async throws -> Response {
        let action = try await resolveStudentAssignmentAction(
            req: req, action: "revoke deadline extensions", writeFloor: .instructor)
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
        let course = try await findActiveCourse(byCode: courseCodeRaw, on: req.db)
        guard let course, let courseUUID = course.id else {
            throw WebAssignmentError.notFound(resource: "Course '\(courseCodeRaw)'")
        }
        guard
            let student = try await APIUser.query(on: req.db)
                .filter(\.$urlToken == urlTokenRaw)
                .first()
        else {
            throw WebAssignmentError.notFound(resource: "Student")
        }
        let isEnrolled =
            try await APICourseEnrollment.query(on: req.db)
            .filter(\.$course.$id == courseUUID)
            .filter(\.$userID == student.id ?? UUID())
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
    /// `/instructor` group's `ActiveCourseInstructorMiddleware` (routes.swift),
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
    /// action's minimum role): grading actions (retest / reset / grade-override)
    /// pass `.ta`; deadline grants (extensions) pass `.instructor`. The read-only
    /// history page leaves it nil so archived courses stay auditable.
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
                courseCode: course.code,
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
        let preferredResultBySubmissionID: [String: APIResult]
        /// "Highest grade wins" percent per submission (#1111) — feeds the
        /// grade cells; `preferredResultBySubmissionID` feeds the badges.
        let bestPercentBySubmissionID: [String: Int]
        let student: APIUser
        let fmt: DateFormatter
        /// `[setupID: disabled built-in award ids]` — the same map for every row.
        let disabledBySetup: [String: Set<String>]
        /// `[setupID: manifest per-submission achievements]` — same map every
        /// row; absent setups fall back to the registry.
        let perSubBySetup: [String: [Achievement]]
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
        let preferredResultBySubmissionID = context.preferredResultBySubmissionID
        let fmt = context.fmt
        let latest = history.first
        // Highest grade across the whole history, from the shared
        // highest-grade-wins map — NOT the worker-preferred result (#1111).
        let bestGradePercent: Int? =
            history
            .compactMap { submission in
                submission.id.flatMap { context.bestPercentBySubmissionID[$0] }
            }
            .max()

        let disabledHere = context.disabledBySetup[assignment.testSetupID] ?? []
        var badges = submissionBadges(
            history: history,
            preferredResultBySubmissionID: preferredResultBySubmissionID,
            achievements: context.perSubBySetup[assignment.testSetupID]
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
            submissionCount: history.count,
            hasLatestSubmission: latest != nil,
            latestSubmissionID: latest?.id ?? "",
            latestSubmittedAtText: latest?.submittedAt.map { fmt.string(from: $0) } ?? "—",
            additionalSubmissionCount: max(history.count - 1, 0),
            bestGradeText: activeOverride.map { "\($0.overridePercent)%" }
                ?? bestGradePercent.map { "\($0)%" },
            gradeIsOverridden: activeOverride != nil,
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

    /// Achievement badges earned on the latest submission (attempt/speed/
    /// improvement).  Class-wide badges are appended by the caller.
    fileprivate func submissionBadges(
        history: [APISubmission],
        preferredResultBySubmissionID: [String: APIResult],
        achievements: [Achievement]?
    ) -> [AchievementBadge] {
        guard let latestSubmission = history.first,
            let latestSubID = latestSubmission.id,
            let result = preferredResultBySubmissionID[latestSubID],
            let collection = decodedCollection(from: result.collectionJSON),
            let gradePct = gradePercent(from: collection)
        else {
            return []
        }
        let latestAttempt = latestSubmission.attemptNumber ?? 1
        let priorSub = history.first(where: { $0.attemptNumber == latestAttempt - 1 })
        let priorPct: Int? = priorSub.flatMap { ps in
            guard let psID = ps.id, let pr = preferredResultBySubmissionID[psID] else {
                return nil
            }
            return pr.gradePercentValue
        }
        return AchievementBadge.forSubmission(
            BadgeContext(
                attemptNumber: latestAttempt,
                gradePercent: gradePct,
                executionTimeMs: collection.executionTimeMs,
                priorGradePercent: priorPct
            ),
            achievements: achievements
        )
    }
}

/// Parses an HTML5 `datetime-local` input value (e.g. `"2026-05-20T23:59"`)
/// into a `Date`.  Both with and without seconds are accepted; the value is
/// interpreted in the Waterloo timezone, matching the rest of the UI.
func parseLocalInputDate(_ input: String) -> Date? {
    let tz = TimeZone(identifier: "America/Toronto") ?? .current
    let candidates = ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss"]
    for fmt in candidates {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = tz
        df.dateFormat = fmt
        if let d = df.date(from: input) { return d }
    }
    return nil
}
