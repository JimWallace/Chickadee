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
    ) -> [AssignmentStatCard] {
        let now = Date()
        let windowStart = now.addingTimeInterval(-24 * 60 * 60)
        let submittedRows = rows.filter { $0.submissionCount > 0 }
        let submittedCount = submittedRows.count
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
        let avgAttempts: String
        if submittedRows.isEmpty {
            avgAttempts = "—"
        } else {
            let total = submittedRows.reduce(0) { $0 + $1.submissionCount }
            let avg = Double(total) / Double(submittedRows.count)
            avgAttempts = String(format: "%.1f", avg)
        }

        let attemptBars = attemptDistributionBars(submittedRows)
        let timelineBars = submissionTimelineBars(submissions, now: now)
        let gradeBars = gradeDistributionBars(gradedRows)

        return [
            AssignmentStatCard(
                label: "Students Submitted",
                value: "\(submittedCount)/\(enrolledStudentRosterCount)",
                hasSpark: false, sparkSummary: "", bars: []),
            AssignmentStatCard(
                label: "Avg Attempts/Student", value: avgAttempts,
                hasSpark: !attemptBars.isEmpty,
                sparkSummary: "Submission attempts per student.", bars: attemptBars),
            AssignmentStatCard(
                label: "Submissions (24h)", value: "\(submissions24h)",
                hasSpark: !timelineBars.isEmpty,
                sparkSummary: "Submissions per day over the last 14 days.", bars: timelineBars),
            AssignmentStatCard(
                label: "Queued Jobs", value: "\(pendingLatestCount)",
                hasSpark: false, sparkSummary: "", bars: []),
            AssignmentStatCard(
                label: "Median Grade", value: medianBestGrade,
                hasSpark: !gradeBars.isEmpty,
                sparkSummary: "Grade distribution across \(countNoun(gradedRows.count, "graded student")).",
                bars: gradeBars),
        ]
    }

    // MARK: - Distribution sparklines

    /// Best-grade distribution in ten 10-point bins (`0–9%` … `90–100%`); the
    /// top bin absorbs 100.  Empty when no student has a graded result.
    private func gradeDistributionBars(_ grades: [Int]) -> [SparklineBar] {
        guard !grades.isEmpty else { return [] }
        var counts = [Int](repeating: 0, count: 10)
        for grade in grades {
            let bin = min(min(max(grade, 0), 100) / 10, 9)
            counts[bin] += 1
        }
        let titles = counts.indices.map { bin -> String in
            let upper = bin == 9 ? 100 : bin * 10 + 9
            return "\(bin * 10)–\(upper)%: \(countNoun(counts[bin], "student"))"
        }
        return sparklineBars(counts: counts, titles: titles)
    }

    /// Attempts-per-student distribution in buckets `1, 2, 3, 4, 5, 6+`.
    /// Empty when no student has submitted.
    private func attemptDistributionBars(_ submittedRows: [AssignmentStudentRow]) -> [SparklineBar] {
        guard !submittedRows.isEmpty else { return [] }
        let bucketCount = 6  // 1, 2, 3, 4, 5, 6+
        var counts = [Int](repeating: 0, count: bucketCount)
        for row in submittedRows {
            counts[min(max(row.submissionCount, 1), bucketCount) - 1] += 1
        }
        let titles = counts.indices.map { bin -> String in
            let attempts: String
            if bin == bucketCount - 1 {
                attempts = "\(bucketCount)+ attempts"
            } else {
                attempts = countNoun(bin + 1, "attempt")
            }
            return "\(attempts): \(countNoun(counts[bin], "student"))"
        }
        return sparklineBars(counts: counts, titles: titles)
    }

    /// Daily submission counts over the most recent 14 days (Waterloo days, to
    /// match the rest of the UI).  Empty when there is no activity in the
    /// window, so the card falls back to its plain headline number.
    private func submissionTimelineBars(_ submissions: [APISubmission], now: Date) -> [SparklineBar] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto") ?? calendar.timeZone
        let today = calendar.startOfDay(for: now)
        let dayCount = 14
        let dayStarts: [Date] = stride(from: dayCount - 1, through: 0, by: -1).compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
        guard dayStarts.count == dayCount else { return [] }
        var counts = [Int](repeating: 0, count: dayCount)
        for submission in submissions {
            guard let submittedAt = submission.submittedAt else { continue }
            if let index = dayStarts.firstIndex(of: calendar.startOfDay(for: submittedAt)) {
                counts[index] += 1
            }
        }
        guard counts.contains(where: { $0 > 0 }) else { return [] }
        let labelFormatter = DateFormatter()
        labelFormatter.locale = Locale(identifier: "en_US_POSIX")
        labelFormatter.timeZone = calendar.timeZone
        labelFormatter.dateFormat = "MMM d"
        let titles = dayStarts.indices.map { index in
            "\(labelFormatter.string(from: dayStarts[index])): \(countNoun(counts[index], "submission"))"
        }
        return sparklineBars(counts: counts, titles: titles)
    }

    /// Normalizes a count series to `[SparklineBar]`, scaling each bar's height
    /// to a 0–100 percentage of the series maximum (matching the JS
    /// `ChickadeeUI.renderSparkline` path used on the dashboards).
    private func sparklineBars(counts: [Int], titles: [String]) -> [SparklineBar] {
        let maxValue = counts.max() ?? 0
        return counts.indices.map { index in
            let height = maxValue > 0 ? Int((Double(counts[index]) / Double(maxValue) * 100).rounded()) : 0
            return SparklineBar(
                heightPercent: height,
                title: index < titles.count ? titles[index] : "")
        }
    }

    private func countNoun(_ count: Int, _ singular: String) -> String {
        "\(count) \(singular)\(count == 1 ? "" : "s")"
    }

}
