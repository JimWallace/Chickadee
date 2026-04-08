// APIServer/Routes/Web/AssignmentRoutes+Submissions.swift
//
// Submission-related handlers for AssignmentRoutes.
// Extracted from AssignmentRoutes.swift — no behaviour changes.

import Vapor
import Fluent
import Foundation

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
        let setups = setupIDs.isEmpty
            ? []
            : try await APITestSetup.query(on: req.db)
                .filter(\.$id ~~ setupIDs)
                .all()
        let setupByID = Dictionary(uniqueKeysWithValues: setups.compactMap { setup in
            setup.id.map { ($0, setup) }
        })

        let sortedAssignments = assignments.sorted { lhs, rhs in
            switch (lhs.sortOrder, rhs.sortOrder) {
            case let (l?, r?) where l != r:
                return l < r
            default:
                let lhsCreated = setupByID[lhs.testSetupID]?.createdAt ?? .distantPast
                let rhsCreated = setupByID[rhs.testSetupID]?.createdAt ?? .distantPast
                if lhsCreated != rhsCreated { return lhsCreated > rhsCreated }
                return lhs.testSetupID < rhs.testSetupID
            }
        }

        let studentIDs = Set(students.compactMap(\.id))
        let submissionRows = (setupIDs.isEmpty || studentIDs.isEmpty)
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

        let results = submissionIDs.isEmpty
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
                  let points = gradePointsFromCollectionJSON(result.collectionJSON) else {
                continue
            }
            let key = "\(submission.userID.uuidString.lowercased())::\(submission.setupID)"
            let prior = bestPointsByUserAndSetup[key] ?? -1
            if points > prior {
                bestPointsByUserAndSetup[key] = points
            }
        }

        var lines: [String] = []
        let header = ["OrgDefinedId", "Username"]
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
    func courseStudentSubmissionsPage(req: Request) async throws -> View {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)
        guard
            let activeCourse = courseState.active,
            let activeCourseUUID = courseState.activeCourseUUID,
            let studentIDRaw = req.parameters.get("studentID"),
            let studentID = UUID(uuidString: studentIDRaw)
        else {
            throw Abort(.badRequest, reason: "No active course selected.")
        }

        let isEnrolled = try await APICourseEnrollment.query(on: req.db)
            .filter(\.$course.$id == activeCourseUUID)
            .filter(\.$userID == studentID)
            .count() > 0
        guard
            isEnrolled,
            let student = try await APIUser.find(studentID, on: req.db),
            student.role == "student"
        else {
            throw Abort(.notFound)
        }

        let setups = try await APITestSetup.query(on: req.db)
            .filter(\.$courseID == activeCourseUUID)
            .all()
        let setupIDs = Set(setups.compactMap(\.id))
        let assignments = setupIDs.isEmpty
            ? []
            : try await APIAssignment.query(on: req.db)
                .filter(\.$testSetupID ~~ setupIDs)
                .all()
        let assignmentBySetupID = Dictionary(
            assignments.map { ($0.testSetupID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let submissions = setupIDs.isEmpty
            ? []
            : try await APISubmission.query(on: req.db)
                .filter(\.$userID == studentID)
                .filter(\.$kind == APISubmission.Kind.student)
                .filter(\.$testSetupID ~~ setupIDs)
                .sort(\.$submittedAt, .descending)
                .all()
        let submissionIDs = submissions.compactMap(\.id)
        let preferredResultBySubmissionID = try await preferredResultsBySubmissionID(
            for: submissionIDs,
            on: req.db
        )

        let fmt = waterlooDateTimeFormatter()
        let rows = submissions.map { submission -> CourseStudentSubmissionRow in
            let submissionID = submission.id ?? ""
            let assignment = assignmentBySetupID[submission.testSetupID]
            let gradeText: String
            if let result = preferredResultBySubmissionID[submissionID],
               let pct = gradePercentFromCollectionJSON(result.collectionJSON) {
                gradeText = "\(pct)%"
            } else {
                gradeText = "—"
            }
            let pathExt = URL(fileURLWithPath: submission.zipPath).pathExtension.lowercased()
            let nameExt = (submission.filename ?? "").lowercased()
            let canOpenInNotebook = pathExt == "ipynb" || nameExt.hasSuffix(".ipynb")
            let openInNotebookURL = canOpenInNotebook
                ? "/testsetups/\(submission.testSetupID)/notebook?submissionID=\(submissionID)"
                : nil
            return CourseStudentSubmissionRow(
                assignmentTitle: assignment?.title ?? "Unpublished setup",
                assignmentSubmissionsURL: assignment.map { "/instructor/\($0.publicID)/submissions" },
                submissionID: submissionID,
                attemptNumber: submission.attemptNumber ?? 1,
                status: submission.status,
                submittedAt: submission.submittedAt.map { fmt.string(from: $0) } ?? "—",
                gradeText: gradeText,
                submissionFilename: submission.filename,
                canOpenInNotebook: canOpenInNotebook,
                openInNotebookURL: openInNotebookURL
            )
        }

        return try await req.view.render(
            "course-student-submissions",
            CourseStudentSubmissionsContext(
                currentUser: req.currentUserContext,
                studentName: student.displayName ?? student.username,
                studentUsername: student.username,
                courseName: "\(activeCourse.code) — \(activeCourse.name)",
                backURL: "/instructor",
                rows: rows
            )
        )
    }

    @Sendable
    func assignmentSubmissionsPage(req: Request) async throws -> View {
        let assignmentIDRaw = try assignmentPublicIDParameter(from: req)
        guard let assignment = try await assignmentByPublicID(assignmentIDRaw, on: req.db) else {
            throw Abort(.notFound)
        }

        let enrolledUserIDs = try await APICourseEnrollment.query(on: req.db)
            .filter(\.$course.$id == assignment.courseID)
            .all()
            .map(\.userID)
        let students = enrolledUserIDs.isEmpty
            ? []
            : try await APIUser.query(on: req.db)
                .filter(\.$role == "student")
                .filter(\.$id ~~ enrolledUserIDs)
                .sort(\.$username, .ascending)
                .all()
        let studentIDs = Set(students.compactMap(\.id))

        let submissions = (studentIDs.isEmpty)
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
                          let pct = gradePercentFromCollectionJSON(result.collectionJSON) else {
                        continue
                    }
                    if pct > best { best = pct }
                }
                return best >= 0 ? best : nil
            }()
            let inferredName = splitHumanName(student.displayName)
                ?? splitHumanName(student.preferredName)
                ?? inferNameFromStudentID(student.username)
            return AssignmentStudentRow(
                studentID: student.username,
                surname: inferredName.surname,
                givenNames: inferredName.givenNames,
                gradeText: bestGradePercent.map { "\($0)%" } ?? "—",
                submissionCount: history.count,
                hasLatestSubmission: latest != nil,
                latestSubmissionID: latest?.id ?? "",
                latestSubmittedAtText: latest?.submittedAt.map { fmt.string(from: $0) } ?? "—",
                additionalSubmissionCount: max(history.count - 1, 0),
                fullHistoryURL: "/instructor/\(assignmentIDRaw)/students/\(studentID.uuidString)/history",
                bestGradePercent: bestGradePercent
            )
        }

        let submittedCount = rows.filter { $0.submissionCount > 0 }.count
        let neverSubmittedCount = max(rows.count - submittedCount, 0)
        let submissions24h = submissions.filter { submission in
            guard let submittedAt = submission.submittedAt else { return false }
            return submittedAt >= windowStart
        }.count
        let pendingLatestCount = rows.reduce(into: 0) { count, row in
            guard row.hasLatestSubmission,
                  let latest = submissions.first(where: { $0.id == row.latestSubmissionID }),
                  ["pending", "assigned"].contains(latest.status) else { return }
            count += 1
        }
        let gradedRows = rows.compactMap(\.bestGradePercent)
        let averageBestGrade = gradedRows.isEmpty
            ? "—"
            : "\(Int((Double(gradedRows.reduce(0, +)) / Double(gradedRows.count)).rounded()))%"
        let metrics = [
            InstructorDashboardMetric(label: "Submitted At Least Once", value: "\(submittedCount)/\(rows.count)"),
            InstructorDashboardMetric(label: "No Submission Yet", value: "\(neverSubmittedCount)"),
            InstructorDashboardMetric(label: "Submissions (24h)", value: "\(submissions24h)"),
            InstructorDashboardMetric(label: "Pending Latest Attempts", value: "\(pendingLatestCount)"),
            InstructorDashboardMetric(label: "Average Best Grade", value: averageBestGrade)
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
            throw Abort(.notFound)
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
               let pct = gradePercentFromCollectionJSON(result.collectionJSON) {
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

        let assignmentIDRaw = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(assignmentIDRaw, on: req.db),
            let submissionID = req.parameters.get("submissionID"),
            let submission = try await APISubmission.find(submissionID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        guard submission.testSetupID == assignment.testSetupID else {
            throw Abort(.notFound)
        }
        guard submission.kind == APISubmission.Kind.student else {
            throw Abort(.badRequest, reason: "Only student submissions can be re-tested.")
        }

        // Prevent duplicate queue entries for in-flight jobs.
        if submission.status != "pending" && submission.status != "assigned" {
            submission.status = "pending"
            submission.workerID = nil
            submission.assignedAt = nil
            submission.retestedAt = Date()
            try await submission.save(on: req.db)
        }

        let body = try? req.content.decode(RetestBody.self)
        let fallbackPath = "/instructor/\(assignmentIDRaw)/submissions"
        let redirectPath = sanitizedAssignmentReturnPath(
            body?.returnTo,
            assignmentIDRaw: assignmentIDRaw,
            fallbackPath: fallbackPath
        )
        return req.redirect(to: redirectPath)
    }
}

private extension AssignmentRoutes {
    func preferredResultsBySubmissionID(
        for submissionIDs: [String],
        on db: Database
    ) async throws -> [String: APIResult] {
        let results = submissionIDs.isEmpty
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
