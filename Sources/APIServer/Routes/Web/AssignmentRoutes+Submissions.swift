// APIServer/Routes/Web/AssignmentRoutes+Submissions.swift
//
// Submission-related handlers for AssignmentRoutes.
// Extracted from AssignmentRoutes.swift — no behaviour changes.

import Fluent
import Foundation
import Vapor

extension AssignmentRoutes {

    // MARK: - GET /instructor/grades.csv

    @Sendable
    func exportGradesCSV(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)

        // Only include students enrolled in the active course (if one is set).
        let students: [APIUser]
        if let activeCourseUUID = courseState.activeCourseUUID {
            let enrolledUserIDs = try await APICourseEnrollment.query(on: req.db)
                .filter(\.$course.$id == activeCourseUUID)
                .all()
                .map { $0.userID }
            let enrolledSet = Set(enrolledUserIDs)
            let allStudents = try await APIUser.query(on: req.db)
                .filter(\.$role == "student")
                .sort(\.$username, .ascending)
                .all()
            students = allStudents.filter { u in u.id.map { enrolledSet.contains($0) } ?? false }
        } else {
            students = try await APIUser.query(on: req.db)
                .filter(\.$role == "student")
                .sort(\.$username, .ascending)
                .all()
        }

        let assignments: [APIAssignment]
        if let activeCourseUUID = courseState.activeCourseUUID {
            assignments = try await APIAssignment.query(on: req.db)
                .filter(\.$courseID == activeCourseUUID)
                .all()
        } else {
            assignments = try await APIAssignment.query(on: req.db).all()
        }
        let setupIDs = Set(assignments.map(\.testSetupID))
        let setups =
            setupIDs.isEmpty
            ? []
            : try await APITestSetup.query(on: req.db)
                .filter(\.$id ~~ setupIDs)
                .all()
        let setupByID = Dictionary(
            uniqueKeysWithValues: setups.compactMap { setup in
                setup.id.map { ($0, setup) }
            })

        let sortedAssignments = assignments.sorted { lhs, rhs in
            switch (lhs.sortOrder, rhs.sortOrder) {
            case (let l?, let r?) where l != r:
                return l < r
            default:
                let lhsCreated = setupByID[lhs.testSetupID]?.createdAt ?? .distantPast
                let rhsCreated = setupByID[rhs.testSetupID]?.createdAt ?? .distantPast
                if lhsCreated != rhsCreated { return lhsCreated > rhsCreated }
                return lhs.testSetupID < rhs.testSetupID
            }
        }

        let studentIDs = Set(students.compactMap(\.id))
        let submissionRows =
            (setupIDs.isEmpty || studentIDs.isEmpty)
            ? []
            : try await APISubmission.query(on: req.db)
                .filter(\.$kind == APISubmission.Kind.student)
                .filter(\.$testSetupID ~~ setupIDs)
                .filter(\.$userID ~~ studentIDs)
                .all()
        let submissions = submissionRows.compactMap { row -> (id: String, userID: UUID, setupID: String)? in
            guard let id = row.id, let userID = row.userID else { return nil }
            return (id, userID, row.testSetupID)
        }
        let submissionIDs = submissions.map(\.id)

        let results =
            submissionIDs.isEmpty
            ? []
            : try await APIResult.query(on: req.db)
                .filter(\.$submissionID ~~ submissionIDs)
                .sort(\.$receivedAt, .descending)
                .all()
        var preferredResultBySubmissionID: [String: APIResult] = [:]
        for result in results {
            let key = result.submissionID
            if let existing = preferredResultBySubmissionID[key] {
                let existingSource = existing.source ?? "worker"
                let candidateSource = result.source ?? "worker"
                if existingSource == "worker" { continue }
                if candidateSource == "worker" {
                    preferredResultBySubmissionID[key] = result
                }
            } else {
                preferredResultBySubmissionID[key] = result
            }
        }

        var bestPointsByUserAndSetup: [String: Double] = [:]
        for submission in submissions {
            guard let result = preferredResultBySubmissionID[submission.id],
                let points = gradePointsFromCollectionJSON(result.collectionJSON)
            else {
                continue
            }
            let key = "\(submission.userID.uuidString.lowercased())::\(submission.setupID)"
            let prior = bestPointsByUserAndSetup[key] ?? -1
            if points > prior {
                bestPointsByUserAndSetup[key] = points
            }
        }

        var lines: [String] = []
        let header =
            ["OrgDefinedId", "Username"]
            + sortedAssignments.map { "\($0.title) Points Grade" }
            + ["End-of-Line Indicator"]
        lines.append(header.map(csvEscaped).joined(separator: ","))

        for student in students {
            guard let userID = student.id else { continue }
            var row: [String] = [student.studentID ?? "", "#\(student.username)"]
            for assignment in sortedAssignments {
                let key = "\(userID.uuidString.lowercased())::\(assignment.testSetupID)"
                if let points = bestPointsByUserAndSetup[key] {
                    row.append(String(format: "%.1f", points))
                } else {
                    row.append("")
                }
            }
            row.append("#")
            lines.append(row.map(csvEscaped).joined(separator: ","))
        }

        let csv = lines.joined(separator: "\n") + "\n"
        let timestamp = Int(Date().timeIntervalSince1970)
        let response = Response(status: .ok)
        response.headers.replaceOrAdd(name: .contentType, value: "text/csv; charset=utf-8")
        response.headers.replaceOrAdd(
            name: .contentDisposition,
            value: "attachment; filename=\"grades-\(timestamp).csv\""
        )
        response.body = .init(string: csv)
        return response
    }

    // MARK: - GET /instructor/:assignmentID/submissions

    @Sendable
    func assignmentSubmissionsPage(req: Request) async throws -> View {
        let assignmentIDRaw = try assignmentPublicIDParameter(from: req)
        guard let assignment = try await assignmentByPublicID(assignmentIDRaw, on: req.db) else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(assignmentIDRaw)'")
        }

        // Canonical roster size: role=="student" enrolled users + pre-enrollments.
        // Matches /admin and /instructor; the table below still only lists
        // logged-in students, so the "Students Submitted" denominator may exceed
        // the row count when pre-enrolled students haven't signed in yet.
        async let enrolledStudentCountFetch = enrolledStudentCount(forCourse: assignment.courseID, on: req.db)

        let enrolledUserIDs = try await APICourseEnrollment.query(on: req.db)
            .filter(\.$course.$id == assignment.courseID)
            .all()
            .map(\.userID)
        let students =
            enrolledUserIDs.isEmpty
            ? []
            : try await APIUser.query(on: req.db)
                .filter(\.$role == "student")
                .filter(\.$id ~~ enrolledUserIDs)
                .sort(\.$username, .ascending)
                .all()
        let studentIDs = Set(students.compactMap(\.id))

        let submissions =
            (studentIDs.isEmpty)
            ? []
            : try await APISubmission.query(on: req.db)
                .filter(\.$testSetupID == assignment.testSetupID)
                .filter(\.$kind == APISubmission.Kind.student)
                .filter(\.$userID ~~ studentIDs)
                .sort(\.$submittedAt, .descending)
                .all()

        var submissionsByStudentID: [UUID: [APISubmission]] = [:]
        for row in submissions {
            guard let userID = row.userID else { continue }
            submissionsByStudentID[userID, default: []].append(row)
        }

        let submissionIDs = submissions.compactMap(\.id)
        let preferredResultBySubmissionID = try await preferredResultsBySubmissionID(
            for: submissionIDs,
            on: req.db
        )

        let fmt = waterlooDateTimeFormatter()
        let windowStart = Date().addingTimeInterval(-24 * 60 * 60)

        let rows = students.compactMap { student -> AssignmentStudentRow? in
            guard let studentID = student.id else { return nil }
            let history = submissionsByStudentID[studentID] ?? []
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
            let inferredName =
                splitHumanName(student.displayName)
                ?? splitHumanName(student.preferredName)
                ?? inferNameFromStudentID(student.username)
            return AssignmentStudentRow(
                studentID: student.username,
                studentUUID: studentID.uuidString,
                surname: inferredName.surname,
                givenNames: inferredName.givenNames,
                gradeText: bestGradePercent.map { "\($0)%" } ?? "—",
                submissionCount: history.count,
                hasLatestSubmission: latest != nil,
                latestSubmissionID: latest?.id ?? "",
                latestSubmittedAtText: latest?.submittedAt.map { fmt.string(from: $0) } ?? "—",
                latestSubmittedAtEpoch: latest?.submittedAt.map { Int($0.timeIntervalSince1970) } ?? 0,
                additionalSubmissionCount: max(history.count - 1, 0),
                fullHistoryURL: "/instructor/\(assignmentIDRaw)/students/\(studentID.uuidString)/history",
                bestGradePercent: bestGradePercent
            )
        }

        let submittedCount = rows.filter { $0.submissionCount > 0 }.count
        let submissions24h = submissions.filter { submission in
            guard let submittedAt = submission.submittedAt else { return false }
            return submittedAt >= windowStart
        }.count
        let pendingLatestCount = rows.reduce(into: 0) { count, row in
            guard row.hasLatestSubmission,
                let latest = submissions.first(where: { $0.id == row.latestSubmissionID }),
                ["pending", "assigned"].contains(latest.status)
            else { return }
            count += 1
        }
        let gradedRows = rows.compactMap(\.bestGradePercent)
        let medianBestGrade: String
        if gradedRows.isEmpty {
            medianBestGrade = "—"
        } else {
            let sorted = gradedRows.sorted()
            let mid = sorted.count / 2
            let median = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
            medianBestGrade = "\(median)%"
        }
        let submittedRows = rows.filter { $0.submissionCount > 0 }
        let avgAttempts: String
        if submittedRows.isEmpty {
            avgAttempts = "—"
        } else {
            let total = submittedRows.reduce(0) { $0 + $1.submissionCount }
            let avg = Double(total) / Double(submittedRows.count)
            avgAttempts = String(format: "%.1f", avg)
        }
        let enrolledStudentRosterCount = try await enrolledStudentCountFetch
        let metrics = [
            InstructorDashboardMetric(
                label: "Students Submitted", value: "\(submittedCount)/\(enrolledStudentRosterCount)"),
            InstructorDashboardMetric(label: "Avg Attempts/Student", value: avgAttempts),
            InstructorDashboardMetric(label: "Submissions (24h)", value: "\(submissions24h)"),
            InstructorDashboardMetric(label: "Queued Jobs", value: "\(pendingLatestCount)"),
            InstructorDashboardMetric(label: "Median Grade", value: medianBestGrade),
        ]

        return try await req.view.render(
            "assignment-submissions",
            AssignmentSubmissionsContext(
                currentUser: req.currentUserContext,
                assignmentID: assignmentIDRaw,
                assignmentTitle: assignment.title,
                metrics: metrics,
                rows: rows
            )
        )
    }

    // MARK: - GET /instructor/:assignmentID/students/:studentID/history

    @Sendable
    func studentSubmissionHistoryPage(req: Request) async throws -> View {
        let assignmentIDRaw = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(assignmentIDRaw, on: req.db),
            let studentIDRaw = req.parameters.get("studentID"),
            let studentID = UUID(uuidString: studentIDRaw),
            let student = try await APIUser.find(studentID, on: req.db),
            student.role == "student"
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
        let preferredResultBySubmissionID = try await preferredResultsBySubmissionID(
            for: submissionIDs,
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
        let assignmentIDRaw = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(assignmentIDRaw, on: req.db),
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
        let assignmentIDRaw = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(assignmentIDRaw, on: req.db),
            let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(assignmentIDRaw)'")
        }

        let count = try await retestAllSubmissionsForSetup(
            setupID: setup.id!,
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
        let assignmentIDRaw = try assignmentPublicIDParameter(from: req)
        guard let assignment = try await assignmentByPublicID(assignmentIDRaw, on: req.db) else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(assignmentIDRaw)'")
        }
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
}

extension AssignmentRoutes {
    func preferredResultsBySubmissionID(
        for submissionIDs: [String],
        on db: Database
    ) async throws -> [String: APIResult] {
        let results =
            submissionIDs.isEmpty
            ? []
            : try await APIResult.query(on: db)
                .filter(\.$submissionID ~~ submissionIDs)
                .sort(\.$receivedAt, .descending)
                .all()

        var preferredResultBySubmissionID: [String: APIResult] = [:]
        for result in results {
            let key = result.submissionID
            if let existing = preferredResultBySubmissionID[key] {
                let existingSource = existing.source ?? "worker"
                let candidateSource = result.source ?? "worker"
                if existingSource == "worker" { continue }
                if candidateSource == "worker" {
                    preferredResultBySubmissionID[key] = result
                }
            } else {
                preferredResultBySubmissionID[key] = result
            }
        }
        return preferredResultBySubmissionID
    }
}
