// APIServer/Routes/Web/InstructorDashboardRoutes+Submissions.swift
//
// The instructor assignment-submissions page
// (GET /instructor/:assignmentID/submissions) and its row/metric builders.
//
// The grades CSV export lives in `InstructorDashboardRoutes+GradesCSV.swift`;
// the per-student actions (history, retest, notebook reset, grade overrides)
// live in `InstructorDashboardRoutes+StudentActions.swift`; the shared
// `preferredResultsBySubmissionID` fold lives in
// `Helpers/PreferredResultsBySubmissionID.swift`.

import Fluent
import Foundation
import Vapor

extension InstructorDashboardRoutes {

    // MARK: - GET /instructor/:assignmentID/submissions

    @Sendable
    func assignmentSubmissionsPage(req: Request) async throws -> View {
        let assignment = try await loadAssignment(req)
        let assignmentIDRaw = assignment.publicID

        // Canonical roster size: role=="student" enrolled users + pre-enrollments.
        // Matches /admin and /instructor; the table below still only lists
        // logged-in students, so the "Students Submitted" denominator may exceed
        // the row count when pre-enrolled students haven't signed in yet.
        async let enrolledStudentCountFetch = enrolledStudentCount(forCourse: assignment.courseID, on: req.db)

        let students = try await loadAssignmentSubmissionsStudents(req: req, assignment: assignment)
        let studentIDs = Set(students.compactMap(\.id))

        let submissions = try await loadAssignmentSubmissionRows(
            req: req, assignment: assignment, studentIDs: studentIDs)
        let submissionsByStudentID = submissionsGroupedByStudentID(submissions)
        let submissionIDs = submissions.compactMap(\.id)
        let preferredResultBySubmissionID = try await preferredResultsBySubmissionID(
            for: submissionIDs, on: req.db)

        // Instructor grade overrides for this assignment, indexed by student.
        let overrideMap = try await loadGradeOverridePercents(
            setupIDs: [assignment.testSetupID], on: req.db)
        var overrideByStudentID: [UUID: Int] = [:]
        for (key, pct) in overrideMap where key.setupID == assignment.testSetupID {
            overrideByStudentID[key.userID] = pct
        }

        let fmt = waterlooDateTimeFormatter()
        let rows = students.compactMap { student -> AssignmentStudentRow? in
            buildAssignmentStudentRow(
                student: student,
                submissionsByStudentID: submissionsByStudentID,
                preferredResultBySubmissionID: preferredResultBySubmissionID,
                overrideByStudentID: overrideByStudentID,
                assignmentIDRaw: assignmentIDRaw,
                fmt: fmt
            )
        }

        let enrolledStudentRosterCount = try await enrolledStudentCountFetch
        let metrics = buildAssignmentSubmissionsMetrics(
            rows: rows,
            submissions: submissions,
            enrolledStudentRosterCount: enrolledStudentRosterCount
        )

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

    // MARK: - assignmentSubmissionsPage helpers

    private func loadAssignmentSubmissionsStudents(
        req: Request, assignment: APIAssignment
    ) async throws -> [APIUser] {
        let enrolledUserIDs = try await APICourseEnrollment.query(on: req.db)
            .filter(\.$course.$id == assignment.courseID)
            .all()
            .map(\.userID)
        guard !enrolledUserIDs.isEmpty else { return [] }
        return try await APIUser.query(on: req.db)
            .filter(\.$role == UserRole.student.rawValue)
            .filter(\.$id ~~ enrolledUserIDs)
            .sort(\.$username, .ascending)
            .all()
    }

    private func loadAssignmentSubmissionRows(
        req: Request, assignment: APIAssignment, studentIDs: Set<UUID>
    ) async throws -> [APISubmission] {
        guard !studentIDs.isEmpty else { return [] }
        return try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == assignment.testSetupID)
            .filter(\.$kind == APISubmission.Kind.student)
            .filter(\.$userID ~~ studentIDs)
            .sort(\.$submittedAt, .descending)
            .all()
    }

    private func submissionsGroupedByStudentID(
        _ submissions: [APISubmission]
    ) -> [UUID: [APISubmission]] {
        var submissionsByStudentID: [UUID: [APISubmission]] = [:]
        for row in submissions {
            guard let userID = row.userID else { continue }
            submissionsByStudentID[userID, default: []].append(row)
        }
        return submissionsByStudentID
    }

    private func buildAssignmentStudentRow(
        student: APIUser,
        submissionsByStudentID: [UUID: [APISubmission]],
        preferredResultBySubmissionID: [String: APIResult],
        overrideByStudentID: [UUID: Int],
        assignmentIDRaw: String,
        fmt: DateFormatter
    ) -> AssignmentStudentRow? {
        guard let studentID = student.id else { return nil }
        let history = submissionsByStudentID[studentID] ?? []
        let latest = history.first
        let runnerBestGradePercent: Int? = {
            var best = -1
            for submission in history {
                guard let subID = submission.id,
                    let result = preferredResultBySubmissionID[subID],
                    let pct = result.gradePercentValue
                else {
                    continue
                }
                if pct > best { best = pct }
            }
            return best >= 0 ? best : nil
        }()
        // An instructor override is the student's effective grade — it feeds
        // both the displayed grade and the median metric.
        let override = overrideByStudentID[studentID]
        let bestGradePercent = override ?? runnerBestGradePercent
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
            gradeIsOverridden: override != nil,
            gradeOverridePercent: override ?? runnerBestGradePercent ?? 0,
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

    private func buildAssignmentSubmissionsMetrics(
        rows: [AssignmentStudentRow],
        submissions: [APISubmission],
        enrolledStudentRosterCount: Int
    ) -> [InstructorDashboardMetric] {
        let windowStart = Date().addingTimeInterval(-24 * 60 * 60)
        let submittedCount = rows.filter { $0.submissionCount > 0 }.count
        let submissions24h = submissions.filter { submission in
            guard let submittedAt = submission.submittedAt else { return false }
            return submittedAt >= windowStart
        }.count
        let pendingLatestCount = rows.reduce(into: 0) { count, row in
            guard row.hasLatestSubmission,
                let latest = submissions.first(where: { $0.id == row.latestSubmissionID }),
                [SubmissionStatus.pending.rawValue, SubmissionStatus.assigned.rawValue].contains(latest.status)
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
        return [
            InstructorDashboardMetric(
                label: "Students Submitted", value: "\(submittedCount)/\(enrolledStudentRosterCount)"),
            InstructorDashboardMetric(label: "Avg Attempts/Student", value: avgAttempts),
            InstructorDashboardMetric(label: "Submissions (24h)", value: "\(submissions24h)"),
            InstructorDashboardMetric(label: "Queued Jobs", value: "\(pendingLatestCount)"),
            InstructorDashboardMetric(label: "Median Grade", value: medianBestGrade),
        ]
    }

}
