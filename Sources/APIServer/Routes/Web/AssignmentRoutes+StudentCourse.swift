// APIServer/Routes/Web/AssignmentRoutes+StudentCourse.swift
//
// Instructor-facing per-student, per-course views, scoped by the URL
// segments `/:courseCode/students/:urlToken/...`.
//
// Mirrors the student dashboard shape (one row per published assignment,
// section grouping, latest submission + best grade + badges) and adds two
// instructor actions per row: per-student retest, and an inline form to
// grant / edit / revoke a deadline extension that lets that one student
// keep submitting after the assignment-wide deadline.

import Core
import Fluent
import Foundation
import Vapor

extension AssignmentRoutes {

    // MARK: - GET /:courseCode/students/:urlToken/submissions

    @Sendable
    func courseStudentSubmissionsPage(req: Request) async throws -> View {
        let viewer = try req.auth.require(APIUser.self)
        guard viewer.isInstructor else {
            throw WebAssignmentError.forbidden(action: "view student submissions")
        }
        let (course, student) = try await resolveCourseAndStudent(req: req)
        guard let courseID = course.id else {
            throw WebAssignmentError.notFound(resource: "Course")
        }

        // Published assignments — i.e. those that have an APIAssignment row.
        // Setups without an assignment are draft/unpublished and never appear
        // in the student-facing dashboard, so they don't appear here either.
        let assignments = try await APIAssignment.query(on: req.db)
            .filter(\.$courseID == courseID)
            .all()

        let setupIDs = assignments.map(\.testSetupID)
        let setupsByID = try await loadStudentCourseSetupsByID(req: req, setupIDs: setupIDs)

        let submissions = try await loadStudentCourseSubmissions(
            req: req, student: student, setupIDs: setupIDs)
        let submissionsBySetupID = submissionsGroupedBySetupID(submissions)
        let preferredResultBySubmissionID = try await preferredResultsBySubmissionID(
            for: submissions.compactMap(\.id),
            on: req.db
        )
        let extensionByAssignmentID = try await loadStudentCourseExtensions(
            req: req, student: student, assignments: assignments)
        let classBadgesBySetupID = try await loadStudentCourseClassBadges(
            req: req, student: student, setupIDs: setupIDs)

        let fmt = waterlooDateTimeFormatter()
        let sortedAssignments = sortedStudentCourseAssignments(assignments, setupsByID: setupsByID)

        let rowContext = StudentAssignmentRowContext(
            courseCode: course.code,
            urlToken: try student.requireURLToken(),
            preferredResultBySubmissionID: preferredResultBySubmissionID,
            student: student,
            fmt: fmt
        )
        let rows = sortedAssignments.map { assignment in
            buildStudentAssignmentRow(
                assignment: assignment,
                history: submissionsBySetupID[assignment.testSetupID] ?? [],
                classBadges: classBadgesBySetupID[assignment.testSetupID] ?? [],
                activeExtension: assignment.id.flatMap { extensionByAssignmentID[$0] },
                context: rowContext
            )
        }

        // Group by course section, just like the student dashboard.
        let allSections = try await APICourseSection.query(on: req.db)
            .filter(\.$courseID == courseID)
            .sort(\.$sortOrder, .ascending)
            .all()
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
        let viewer = try req.auth.require(APIUser.self)
        guard viewer.isInstructor else {
            throw WebAssignmentError.forbidden(action: "view student submission history")
        }
        let (course, student) = try await resolveCourseAndStudent(req: req)
        let assignmentIDRaw = try assignmentPublicIDParameter(from: req)
        guard let assignment = try await assignmentByPublicID(assignmentIDRaw, on: req.db),
            assignment.courseID == course.id
        else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(assignmentIDRaw)'")
        }

        let submissions: [APISubmission]
        if let studentUUID = student.id {
            submissions = try await APISubmission.query(on: req.db)
                .filter(\.$testSetupID == assignment.testSetupID)
                .filter(\.$userID == studentUUID)
                .filter(\.$kind == APISubmission.Kind.student)
                .sort(\.$submittedAt, .descending)
                .all()
        } else {
            submissions = []
        }
        let preferredResultBySubmissionID = try await preferredResultsBySubmissionID(
            for: submissions.compactMap(\.id),
            on: req.db
        )

        let fmt = waterlooDateTimeFormatter()
        let rows = submissions.map { submission -> AssignmentSubmissionHistoryRow in
            let subID = submission.id ?? ""
            let gradeText: String
            if let result = preferredResultBySubmissionID[subID],
                let pct = gradePercentFromCollectionJSON(result.collectionJSON)
            {
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
        let actor = try req.auth.require(APIUser.self)
        guard actor.isInstructor else {
            throw WebAssignmentError.forbidden(action: "retest student submissions")
        }
        let (course, student) = try await resolveCourseAndStudent(req: req)
        let assignmentIDRaw = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(assignmentIDRaw, on: req.db),
            assignment.courseID == course.id,
            let studentID = student.id
        else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(assignmentIDRaw)'")
        }

        let count = try await retestStudentSubmissionsForSetup(
            setupID: assignment.testSetupID,
            studentUserID: studentID,
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

        return req.redirect(
            to: StudentCoursePaths.submissions(
                courseCode: course.code,
                urlToken: try student.requireURLToken()
            )
        )
    }

    // MARK: - POST /:courseCode/students/:urlToken/assignments/:assignmentID/extension

    @Sendable
    func saveStudentAssignmentExtension(req: Request) async throws -> Response {
        struct ExtensionBody: Content {
            var extendedDueAt: String?
            var note: String?
        }

        let actor = try req.auth.require(APIUser.self)
        guard actor.isInstructor else {
            throw WebAssignmentError.forbidden(action: "grant deadline extensions")
        }
        let (course, student) = try await resolveCourseAndStudent(req: req)
        let assignmentIDRaw = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(assignmentIDRaw, on: req.db),
            assignment.courseID == course.id,
            let assignmentUUID = assignment.id,
            let studentUUID = student.id
        else {
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

        return req.redirect(
            to: StudentCoursePaths.submissions(
                courseCode: course.code,
                urlToken: try student.requireURLToken()
            )
        )
    }

    // MARK: - POST /:courseCode/students/:urlToken/assignments/:assignmentID/extension/delete

    @Sendable
    func deleteStudentAssignmentExtension(req: Request) async throws -> Response {
        let actor = try req.auth.require(APIUser.self)
        guard actor.isInstructor else {
            throw WebAssignmentError.forbidden(action: "revoke deadline extensions")
        }
        let (course, student) = try await resolveCourseAndStudent(req: req)
        let assignmentIDRaw = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(assignmentIDRaw, on: req.db),
            assignment.courseID == course.id,
            let assignmentUUID = assignment.id,
            let studentUUID = student.id
        else {
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

        return req.redirect(
            to: StudentCoursePaths.submissions(
                courseCode: course.code,
                urlToken: try student.requireURLToken()
            )
        )
    }
}

// MARK: - Private helpers

extension AssignmentRoutes {
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
        let courseCode = courseCodeRaw.lowercased()
        let course =
            try await APICourse.query(on: req.db)
            .filter(\.$isArchived == false)
            .all()
            .first(where: { $0.code.lowercased() == courseCode })
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

    /// Bundles the per-table inputs that don't vary across rows.  Lets
    /// `buildStudentAssignmentRow` stay at 5 parameters even with 9
    /// logical inputs.  `urlToken` is the student's opaque URL token
    /// (#556) — used to build per-student action URLs without leaking
    /// the username into request logs.
    fileprivate struct StudentAssignmentRowContext {
        let courseCode: String
        let urlToken: String
        let preferredResultBySubmissionID: [String: APIResult]
        let student: APIUser
        let fmt: DateFormatter
    }

    fileprivate func buildStudentAssignmentRow(
        assignment: APIAssignment,
        history: [APISubmission],
        classBadges: [AchievementBadge],
        activeExtension: APIAssignmentExtension?,
        context: StudentAssignmentRowContext
    ) -> StudentAssignmentRow {
        let courseCode = context.courseCode
        let urlToken = context.urlToken
        let preferredResultBySubmissionID = context.preferredResultBySubmissionID
        let student = context.student
        let fmt = context.fmt
        let latest = history.first
        let bestGradePercent: Int? = {
            var best = -1
            for submission in history {
                guard let subID = submission.id,
                    let result = preferredResultBySubmissionID[subID],
                    let pct = gradePercentFromCollectionJSON(result.collectionJSON)
                else {
                    continue
                }
                if pct > best { best = pct }
            }
            return best >= 0 ? best : nil
        }()

        var badges: [AchievementBadge] = []
        if let latestSubmission = latest,
            let latestSubID = latestSubmission.id,
            let result = preferredResultBySubmissionID[latestSubID],
            let collection = visibleCollection(
                from: result.collectionJSON,
                for: student,
                assignment: assignment
            ),
            let gradePct = gradePercent(from: collection)
        {
            let latestAttempt = latestSubmission.attemptNumber ?? 1
            let priorSub = history.first(where: { $0.attemptNumber == latestAttempt - 1 })
            let priorPct: Int? = priorSub.flatMap { ps in
                guard let psID = ps.id, let pr = preferredResultBySubmissionID[psID] else {
                    return nil
                }
                return gradePercentFromCollectionJSON(pr.collectionJSON)
            }
            badges.append(
                contentsOf: AchievementBadge.forSubmission(
                    BadgeContext(
                        attemptNumber: latestAttempt,
                        gradePercent: gradePct,
                        executionTimeMs: collection.executionTimeMs,
                        priorGradePercent: priorPct
                    )
                )
            )
        }
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
            status: assignment.isOpen ? "open" : "closed",
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
            bestGradeText: bestGradePercent.map { "\($0)%" },
            badges: badges
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
