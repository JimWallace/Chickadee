// APIServer/Routes/Web/InstructorDashboardRoutes+StudentActions.swift
//
// Per-student instructor actions on one assignment: submission history,
// retest (single submission + retest-all), notebook reset, and grade
// override save/delete.  Split out of
// InstructorDashboardRoutes+Submissions.swift — no behaviour changes.

import Fluent
import Foundation
import Vapor

extension InstructorDashboardRoutes {

    // MARK: - GET /instructor/:assignmentID/students/:studentID/history

    @Sendable
    func studentSubmissionHistoryPage(req: Request) async throws -> View {
        let assignment = try await loadAssignmentForStaffRead(req)
        let assignmentIDRaw = assignment.publicID
        guard
            let studentIDRaw = req.parameters.get("studentID"),
            let studentID = UUID(uuidString: studentIDRaw),
            let student = try await APIUser.find(studentID, on: req.db),
            // Student-ness is per-course now (#417 Slice G2): the target must
            // hold a `.student` enrollment in this assignment's course.
            try await courseRole(of: studentID, inCourse: assignment.courseID, db: req.db) == .student
        else {
            throw WebAssignmentError.notFound(resource: "Assignment or student")
        }

        let submissions = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == assignment.testSetupID)
            .filter(\.$userID == studentID)
            .filter(\.$kind == APISubmission.Kind.student)
            .sort(\.$submittedAt, .descending)
            .all()
        let submissionIDs = submissions.compactMap(\.id)
        // "Highest grade wins" across ALL result sources — the same fold the
        // roster the instructor clicked through from uses, so the two pages
        // can't show different numbers for the same submission (#1111; this
        // page used to show the worker-preferred grade instead).
        let bestPercentBySubmissionID = try await bestGradePercentBySubmissionID(
            for: submissionIDs,
            on: req.db
        )

        let fmt = waterlooDateTimeFormatter()
        let rows = assignmentSubmissionHistoryRows(
            submissions: submissions,
            bestPercentBySubmissionID: bestPercentBySubmissionID,
            fmt: fmt)

        return try await req.view.render(
            "assignment-student-history",
            AssignmentStudentHistoryContext(
                currentUser: req.currentUserContext,
                assignmentID: assignmentIDRaw,
                assignmentTitle: assignment.title,
                studentID: student.username,
                historyPath: "/instructor/\(assignmentIDRaw)/students/\(studentIDRaw)/history",
                rows: rows
            )
        )
    }

    // MARK: - POST /instructor/:assignmentID/submissions/:submissionID/retest

    @Sendable
    func retestSubmission(req: Request) async throws -> Response {
        struct RetestBody: Content {
            var returnTo: String?
        }

        let user = try req.auth.require(APIUser.self)
        let assignment = try await loadAssignmentForWrite(req, atLeast: .ta)
        let assignmentIDRaw = assignment.publicID
        guard
            let submissionID = req.parameters.get("submissionID"),
            let submission = try await APISubmission.find(submissionID, on: req.db)
        else {
            throw WebAssignmentError.notFound(resource: "Submission")
        }

        guard submission.testSetupID == assignment.testSetupID else {
            throw WebAssignmentError.notFound(resource: "Submission")
        }
        guard submission.kind == APISubmission.Kind.student else {
            throw WebAssignmentError.invalidParameter(
                name: "submissionID", reason: "Only student submissions can be re-tested.")
        }

        _ = try await flipSubmissionToPending(
            submission,
            triggeredBy: user.id,
            on: req.db
        )

        let body = try? req.content.decode(RetestBody.self)
        let fallbackPath = "/instructor/\(assignmentIDRaw)/submissions"
        let redirectPath = sanitizedAssignmentReturnPath(
            body?.returnTo,
            assignmentIDRaw: assignmentIDRaw,
            fallbackPath: fallbackPath
        )
        return req.redirect(to: redirectPath)
    }

    // MARK: - POST /instructor/:assignmentID/retest
    //
    // "Retest all" — fans out a retest to every student submission on the
    // assignment's test setup.  The manual sibling of the auto-retest
    // trigger in `saveEditedAssignment`.  Always runs with `force = true`
    // so an instructor click re-enqueues even the submissions currently
    // being worked on (the queue can safely collapse duplicates at claim
    // time; we'd rather over-trigger than silently skip on a retry).
    //
    // Bumps `setup.lastRetestedManifestHash` on success so a subsequent
    // cosmetic Save doesn't duplicate the work.

    @Sendable
    func retestAllSubmissions(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let (assignment, setup) = try await loadAssignmentAndSetupForWrite(req, atLeast: .ta)
        let assignmentIDRaw = assignment.publicID

        let count = try await retestAllSubmissionsForSetup(
            setupID: assignment.testSetupID,
            triggeredBy: user.id,
            on: req.db,
            force: true
        )

        setup.lastRetestedManifestHash = manifestHash(setup.manifest)
        try await setup.save(on: req.db)

        req.logger.info(
            "retest_all_triggered assignment=\(assignmentIDRaw) count=\(count) by=\(user.id?.uuidString ?? "nil")")
        await AuditLogger.record(
            action: .submissionRetestAll,
            targetType: .testSetup,
            targetID: setup.id,
            metadata: [
                "assignment": assignmentIDRaw,
                "submission_count": String(count),
            ],
            on: req
        )

        let fallbackPath = "/instructor/\(assignmentIDRaw)/submissions"
        struct RetestAllBody: Content { var returnTo: String? }
        let body = try? req.content.decode(RetestAllBody.self)
        let redirectPath = sanitizedAssignmentReturnPath(
            body?.returnTo,
            assignmentIDRaw: assignmentIDRaw,
            fallbackPath: fallbackPath
        )
        return req.redirect(to: redirectPath)
    }

    // MARK: - POST /instructor/:assignmentID/students/:studentID/reset-notebook
    //
    // Instructor-driven reset of a student's working-copy notebook back to
    // the canonical starter from the test setup.  Used when a student has
    // corrupted their own notebook (e.g. uploaded a broken `.ipynb` that
    // overwrote their working copy) and needs to start over from the
    // original assignment.
    //
    // Past submissions are NOT deleted — they remain in the database and
    // on disk for forensic / grading review.  Only the live working copy
    // at jupyterlite/files/users/{userID}/{setupID}/<filename> is
    // overwritten.
    //
    // Note for the student: the new starter is on the server, but the
    // student's browser may still have the broken version cached in
    // JupyterLite's IndexedDB.  The student should clear site data for
    // chickadee.uwaterloo.ca (or use an incognito window) on their next
    // visit for the reset to take effect end-to-end.
    @Sendable
    func resetStudentNotebook(req: Request) async throws -> Response {
        struct ResetBody: Content {
            var returnTo: String?
        }

        let user = try req.auth.require(APIUser.self)
        let assignment = try await loadAssignmentForWrite(req, atLeast: .ta)
        let assignmentIDRaw = assignment.publicID
        guard let studentIDRaw = req.parameters.get("studentID"),
            let studentID = UUID(uuidString: studentIDRaw)
        else {
            throw WebAssignmentError.notFound(resource: "Student")
        }
        guard let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db) else {
            throw WebAssignmentError.notFound(resource: "Test setup")
        }

        let isEnrolled =
            try await APICourseEnrollment.query(on: req.db)
            .filter(\.$course.$id == assignment.courseID)
            .filter(\.$userID == studentID)
            .count() > 0
        guard isEnrolled else {
            throw WebAssignmentError.notFound(resource: "Enrolled student '\(studentIDRaw)'")
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
            userID: studentID,
            fallbackSetup: setup,
            overwriteWith: starter
        )

        req.logger.info(
            "student_notebook_reset assignment=\(assignmentIDRaw) student=\(studentIDRaw) by=\(user.id?.uuidString ?? "nil")"
        )

        let fallbackPath = "/instructor/\(assignmentIDRaw)/submissions"
        let body = try? req.content.decode(ResetBody.self)
        let redirectPath = sanitizedAssignmentReturnPath(
            body?.returnTo,
            assignmentIDRaw: assignmentIDRaw,
            fallbackPath: fallbackPath
        )
        return req.redirect(to: redirectPath)
    }

    // MARK: - POST /instructor/:assignmentID/students/:studentID/grade-override
    //
    // Per-assignment-roster twin of the grouped per-student page's grade
    // override.  Both resolve to the same (test_setup, user) row and share
    // `applyGradeOverride` / `clearGradeOverride`, so an override set from
    // either page is identical and replaces the runner-computed grade
    // everywhere (roster median, grades CSV, BrightSpace sync, submission
    // view).  Student identity here is the UUID path segment, matching the
    // sibling `reset-notebook` action on this same page.

    @Sendable
    func saveStudentGradeOverride(req: Request) async throws -> Response {
        struct OverrideBody: Content {
            var overridePercent: Int?
            var note: String?
            var returnTo: String?
        }

        let actor = try req.auth.require(APIUser.self)
        let assignment = try await loadAssignmentForWrite(req, atLeast: .ta)
        let assignmentIDRaw = assignment.publicID
        let student = try await resolveEnrolledStudent(req: req, assignment: assignment)
        guard let studentUUID = student.id else {
            throw WebAssignmentError.notFound(resource: "Student")
        }

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
            testSetupID: assignment.testSetupID,
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

        let fallbackPath = "/instructor/\(assignmentIDRaw)/submissions"
        let redirectPath = sanitizedAssignmentReturnPath(
            body.returnTo, assignmentIDRaw: assignmentIDRaw, fallbackPath: fallbackPath)
        return req.redirect(to: redirectPath)
    }

    // MARK: - POST /instructor/:assignmentID/students/:studentID/grade-override/delete

    @Sendable
    func deleteStudentGradeOverride(req: Request) async throws -> Response {
        struct DeleteBody: Content { var returnTo: String? }

        _ = try req.auth.require(APIUser.self)
        let assignment = try await loadAssignmentForWrite(req, atLeast: .ta)
        let assignmentIDRaw = assignment.publicID
        let student = try await resolveEnrolledStudent(req: req, assignment: assignment)
        guard let studentUUID = student.id else {
            throw WebAssignmentError.notFound(resource: "Student")
        }

        if try await clearGradeOverride(
            testSetupID: assignment.testSetupID, studentUserID: studentUUID, on: req.db)
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

        let body = try? req.content.decode(DeleteBody.self)
        let fallbackPath = "/instructor/\(assignmentIDRaw)/submissions"
        let redirectPath = sanitizedAssignmentReturnPath(
            body?.returnTo, assignmentIDRaw: assignmentIDRaw, fallbackPath: fallbackPath)
        return req.redirect(to: redirectPath)
    }

    /// Resolves the `:studentID` UUID parameter to a `role == "student"` user
    /// enrolled in the assignment's course.  Throws `notFound` when the
    /// parameter is missing/invalid, the user doesn't exist or isn't a
    /// student, or the user isn't enrolled — the same gate `resetStudentNotebook`
    /// applies, so per-student instructor actions stay scoped to the roster.
    private func resolveEnrolledStudent(
        req: Request, assignment: APIAssignment
    ) async throws -> APIUser {
        guard let studentIDRaw = req.parameters.get("studentID"),
            let studentID = UUID(uuidString: studentIDRaw),
            let student = try await APIUser.find(studentID, on: req.db)
        else {
            throw WebAssignmentError.notFound(resource: "Student")
        }
        // Student-ness is per-course now (#417 Slice G2): require a `.student`
        // enrollment in the assignment's course. This subsumes the old
        // global-role check *and* the separate enrollment query — a non-enrolled
        // user has no per-course role, so `courseRole` returns nil.
        guard
            try await courseRole(of: studentID, inCourse: assignment.courseID, db: req.db) == .student
        else {
            throw WebAssignmentError.notFound(resource: "Enrolled student")
        }
        return student
    }
}
