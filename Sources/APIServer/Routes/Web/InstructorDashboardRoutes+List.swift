// APIServer/Routes/Web/InstructorDashboardRoutes+List.swift
//
// Helpers for the GET /instructor handler (`AssignmentRoutes.list`).
// Split out per #443: the original handler interleaved Fluent queries,
// dashboard-metric computation, row construction, sorting, and section
// grouping in one ~380-line block.  These helpers expose each step as a
// focused unit so a UI fix to one slice doesn't require re-reading the
// other four.

import Core
import Fluent
import Foundation
import Vapor

// MARK: - Intermediate query results

/// Aggregated student-roster data + dashboard metrics for the active course.
/// `enrolledStudents` includes pending pre-enrollments at the tail.
struct CourseRosterData {
    let enrolledStudents: [EnrolledStudentRow]
    let enrolledStudentIDs: Set<UUID>
    let enrolledStudentCount: Int
    let metrics: [InstructorDashboardMetric]
}

extension InstructorDashboardRoutes {

    // MARK: - Setup + assignment fetches

    /// Returns all `APITestSetup` rows for the active course (or all
    /// setups if no course is active), sorted newest-first.
    func loadCourseSetups(
        req: Request,
        activeCourseUUID: UUID?
    ) async throws -> [APITestSetup] {
        if let activeCourseUUID {
            return try await APITestSetup.query(on: req.db)
                .filter(\.$courseID == activeCourseUUID)
                .sort(\.$createdAt, .descending)
                .all()
        }
        return try await APITestSetup.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .all()
    }

    /// Returns all `APIAssignment` rows for the active course (or all
    /// assignments if no course is active).  Order is unspecified — sorting
    /// happens later, after rows are joined to setups.
    func loadCourseAssignments(
        req: Request,
        activeCourseUUID: UUID?
    ) async throws -> [APIAssignment] {
        if let activeCourseUUID {
            return try await APIAssignment.query(on: req.db)
                .filter(\.$courseID == activeCourseUUID)
                .all()
        }
        return try await APIAssignment.query(on: req.db).all()
    }

    /// Course sections, sorted by ascending `sortOrder`.
    func loadCourseSections(
        req: Request,
        activeCourseUUID: UUID?
    ) async throws -> [APICourseSection] {
        if let activeCourseUUID {
            return try await APICourseSection.query(on: req.db)
                .filter(\.$courseID == activeCourseUUID)
                .sort(\.$sortOrder, .ascending)
                .all()
        }
        return try await APICourseSection.query(on: req.db)
            .sort(\.$sortOrder, .ascending)
            .all()
    }

    // MARK: - Roster + dashboard metrics

    /// Builds the enrolled-students table and the five dashboard metric
    /// cards.  Only enrolled users with `role == "student"` count toward the
    /// numerators / denominators on the per-assignment "X / Y" badge — admin
    /// or instructor users enrolled for testing must not inflate the
    /// student-facing counters.  Pending CSV-uploaded pre-enrollments are
    /// shown as muted rows in the same table and are counted toward the
    /// "Y students enrolled" denominator.
    func buildCourseRoster(
        req: Request,
        activeCourseUUID: UUID,
        activeCourseCode: String,
        allSetupIDs: [String],
        fmt: DateFormatter,
        isoFormatter: ISO8601DateFormatter
    ) async throws -> CourseRosterData {
        let enrolledUsers = try await loadEnrolledUsersForRoster(req: req, activeCourseUUID: activeCourseUUID)
        var enrolledStudents = buildEnrolledStudentRows(
            enrolledUsers: enrolledUsers,
            activeCourseUUID: activeCourseUUID,
            activeCourseCode: activeCourseCode,
            fmt: fmt,
            isoFormatter: isoFormatter
        )

        // Pre-enrolled (pending) — bulk-CSV entries that haven't been
        // claimed by a first SSO/local login yet.  Showing them keeps the
        // count matching what the instructor uploaded.
        let pendingPreEnrollments = try await APIPreEnrollment.query(on: req.db)
            .filter(\.$course.$id == activeCourseUUID)
            .sort(\.$username)
            .all()
        enrolledStudents.append(
            contentsOf: buildPendingPreEnrollmentRows(
                pendingPreEnrollments: pendingPreEnrollments,
                activeCourseUUID: activeCourseUUID
            )
        )

        let activeStudentIDs = Set(
            enrolledUsers
                .filter { $0.role == "student" }
                .compactMap(\.id)
        )
        // Pending pre-enrollments are CSV-uploaded students who haven't
        // logged in yet — count them toward the "Y students enrolled"
        // denominator so the badge reflects the instructor's roster intent,
        // not just who's logged in.
        let enrolledStudentCount = activeStudentIDs.count + pendingPreEnrollments.count

        let metrics = try await buildCourseRosterMetrics(
            req: req,
            allSetupIDs: allSetupIDs,
            enrolledUsers: enrolledUsers,
            activeStudentIDs: activeStudentIDs
        )

        return CourseRosterData(
            enrolledStudents: enrolledStudents,
            enrolledStudentIDs: activeStudentIDs,
            enrolledStudentCount: enrolledStudentCount,
            metrics: metrics
        )
    }

    /// Loads the enrolled users for the course, sorted last-seen-desc then
    /// username-asc.  Returns an empty array if no enrollments exist.
    private func loadEnrolledUsersForRoster(
        req: Request,
        activeCourseUUID: UUID
    ) async throws -> [APIUser] {
        let enrollments = try await APICourseEnrollment.query(on: req.db)
            .filter(\.$course.$id == activeCourseUUID)
            .all()
        let enrolledUserIDs = enrollments.map(\.userID)
        guard !enrolledUserIDs.isEmpty else { return [] }
        return try await APIUser.query(on: req.db)
            .filter(\.$id ~~ enrolledUserIDs)
            .all()
            .sorted { lhs, rhs in
                switch (lhs.lastSeenAt, rhs.lastSeenAt) {
                case (let l?, let r?):
                    if l != r { return l > r }
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                case (nil, nil):
                    break
                }
                return lhs.username.localizedStandardCompare(rhs.username) == .orderedAscending
            }
    }

    private func buildEnrolledStudentRows(
        enrolledUsers: [APIUser],
        activeCourseUUID: UUID,
        activeCourseCode: String,
        fmt: DateFormatter,
        isoFormatter: ISO8601DateFormatter
    ) -> [EnrolledStudentRow] {
        enrolledUsers.compactMap { u in
            guard let id = u.id else { return nil }
            // Skip rows that somehow lack a urlToken instead of failing
            // the whole roster render — the invariant says every user has
            // one (init default + AddUrlTokenToUsers backfill), so this
            // branch is unreachable in practice but kept for safety.
            guard let token = u.urlToken, !token.isEmpty else { return nil }
            return EnrolledStudentRow(
                id: id.uuidString,
                username: u.username,
                displayName: u.displayName ?? u.username,
                role: u.role,
                lastSeenAtText: u.lastSeenAt.map { fmt.string(from: $0) } ?? "—",
                lastSeenAtISO: u.lastSeenAt.map { isoFormatter.string(from: $0) },
                submissionsURL: studentSubmissionsURL(
                    courseCode: activeCourseCode,
                    urlToken: token
                ),
                unenrollURL: "/courses/\(activeCourseUUID.uuidString)/unenroll/\(id.uuidString)",
                isPending: false
            )
        }
    }

    private func buildPendingPreEnrollmentRows(
        pendingPreEnrollments: [APIPreEnrollment],
        activeCourseUUID: UUID
    ) -> [EnrolledStudentRow] {
        pendingPreEnrollments.compactMap { p -> EnrolledStudentRow? in
            guard let preID = p.id else { return nil }
            return EnrolledStudentRow(
                id: preID.uuidString,
                username: p.username,
                displayName: p.username,
                role: "(pending)",
                lastSeenAtText: "—",
                lastSeenAtISO: nil,
                submissionsURL: "#",
                unenrollURL: "/courses/\(activeCourseUUID.uuidString)/pre-unenroll/\(preID.uuidString)",
                isPending: true
            )
        }
    }

    /// Computes the five dashboard metric cards from recent submissions,
    /// queue depth, and client diagnostics.
    private func buildCourseRosterMetrics(
        req: Request,
        allSetupIDs: [String],
        enrolledUsers: [APIUser],
        activeStudentIDs: Set<UUID>
    ) async throws -> [InstructorDashboardMetric] {
        let now = Date()
        let windowStart = now.addingTimeInterval(-24 * 60 * 60)
        let recentSubmissions =
            allSetupIDs.isEmpty
            ? []
            : try await APISubmission.query(on: req.db)
                .filter(\.$testSetupID ~~ allSetupIDs)
                .filter(\.$kind == APISubmission.Kind.student)
                .filter(\.$submittedAt >= windowStart)
                .all()
        let allCourseStudentSubmissions =
            allSetupIDs.isEmpty
            ? []
            : try await APISubmission.query(on: req.db)
                .filter(\.$testSetupID ~~ allSetupIDs)
                .filter(\.$kind == APISubmission.Kind.student)
                .all()
        let workerModeSetupIDs = try await req.application.diagnostics.workerModeTestSetupIDs(
            for: allSetupIDs,
            on: req.db
        )

        let active24h = enrolledUsers.reduce(into: 0) { count, user in
            guard user.role == "student" else { return }
            if let lastSeenAt = user.lastSeenAt, lastSeenAt >= windowStart {
                count += 1
            }
        }

        let recentStudentSubmissions = recentSubmissions.filter { submission in
            guard let userID = submission.userID else { return false }
            return activeStudentIDs.contains(userID)
        }
        let activeAssignments24h = Set(recentStudentSubmissions.map(\.testSetupID)).count
        let pendingNow = allCourseStudentSubmissions.filter { submission in
            guard let userID = submission.userID else { return false }
            return activeStudentIDs.contains(userID)
                && workerModeSetupIDs.contains(submission.testSetupID)
                && ["pending", "assigned"].contains(submission.status)
        }.count
        let studentsWithBrowserErrors = try await countStudentsWithBrowserErrors(
            req: req,
            allSetupIDs: allSetupIDs,
            activeStudentIDs: activeStudentIDs,
            windowStart: windowStart
        )

        return [
            InstructorDashboardMetric(label: "24h Active", value: "\(active24h)"),
            InstructorDashboardMetric(label: "24h Submissions", value: "\(recentStudentSubmissions.count)"),
            InstructorDashboardMetric(label: "Assignments Active (24h)", value: "\(activeAssignments24h)"),
            InstructorDashboardMetric(label: "Queued Right Now", value: "\(pendingNow)"),
            InstructorDashboardMetric(label: "Students With Browser Errors", value: "\(studentsWithBrowserErrors)"),
        ]
    }

    /// Students With Browser Errors: distinct students who posted a
    /// client-side diagnostic (preflight_fail or watchdog_timeout) for
    /// one of this course's test setups within the 24h window.  Captures
    /// the in-browser editor failing to start — JupyterLite / Pyodide
    /// blocked by browser policy, IndexedDB disabled, service worker
    /// blocked, etc. — before the student can even open the assignment.
    /// Diagnostics with a null test_setup_id (the supplied setup ID didn't
    /// resolve) are excluded since they can't be attributed to a course.
    private func countStudentsWithBrowserErrors(
        req: Request,
        allSetupIDs: [String],
        activeStudentIDs: Set<UUID>,
        windowStart: Date
    ) async throws -> Int {
        let setupIDSet = Set(allSetupIDs)
        let recentClientDiagnostics =
            allSetupIDs.isEmpty
            ? []
            : try await APIClientDiagnostic.query(on: req.db)
                .filter(\.$createdAt >= windowStart)
                .all()
        return Set(
            recentClientDiagnostics.compactMap { record -> UUID? in
                guard let setupID = record.testSetupID,
                    setupIDSet.contains(setupID),
                    activeStudentIDs.contains(record.userID)
                else { return nil }
                return record.userID
            }
        ).count
    }

    /// Five "—" placeholder cards for use when no course is active.
    static func placeholderDashboardMetrics() -> [InstructorDashboardMetric] {
        [
            InstructorDashboardMetric(label: "24h Active", value: "—"),
            InstructorDashboardMetric(label: "24h Submissions", value: "—"),
            InstructorDashboardMetric(label: "Assignments Active (24h)", value: "—"),
            InstructorDashboardMetric(label: "Queued Right Now", value: "—"),
            InstructorDashboardMetric(label: "Students With Browser Errors", value: "—"),
        ]
    }

    // MARK: - Per-assignment unique-submitter counts

    /// Returns `[testSetupID: distinctSubmitterCount]` filtered to the
    /// supplied `enrolledStudentIDs` (so admin/instructor test submissions
    /// don't inflate the per-assignment badge).
    func loadUniqueSubmittersBySetup(
        req: Request,
        allSetupIDs: [String],
        enrolledStudentIDs: Set<UUID>
    ) async throws -> [String: Int] {
        guard !allSetupIDs.isEmpty, !enrolledStudentIDs.isEmpty else { return [:] }
        let studentSubmissions = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID ~~ allSetupIDs)
            .filter(\.$kind == APISubmission.Kind.student)
            .filter(\.$userID ~~ Array(enrolledStudentIDs))
            .all()
        var submitterSets: [String: Set<UUID>] = [:]
        for sub in studentSubmissions {
            guard let uid = sub.userID else { continue }
            submitterSets[sub.testSetupID, default: []].insert(uid)
        }
        return submitterSets.mapValues { $0.count }
    }

    // MARK: - Row construction

    /// Builds an `AssignmentRow` for each setup, joining the matching
    /// assignment (if any) and computing the suite count, status, and
    /// vanity URL.
    func buildAssignmentRows(
        allSetups: [APITestSetup],
        assignmentBySetup: [String: APIAssignment],
        uniqueSubmittersBySetup: [String: Int],
        activeCourse: CourseContext?,
        fmt: DateFormatter
    ) -> [AssignmentRow] {
        allSetups.map { setup in
            let assignment = assignmentBySetup[setup.id ?? ""]
            let setupID = setup.id ?? ""
            let suiteCount: Int = {
                guard let props = setup.decodedManifest()

                else { return 0 }
                return props.testSuites.count
            }()

            let status: String
            if let a = assignment {
                status = a.isOpen ? "open" : "closed"
            } else {
                status = "unpublished"
            }
            let validationStatus = assignment?.validationStatus ?? (assignment == nil ? "unpublished" : "passed")
            let validationSubmissionID = assignment?.validationSubmissionID

            let vanityURL: String? = {
                guard let assignment,
                    let title = assignment.title as String?, !title.isEmpty,
                    let courseCode = activeCourse?.code, !courseCode.isEmpty,
                    !assignment.slug.isEmpty
                else { return nil }
                return VanityURLRoutes.vanityPath(courseCode: courseCode, assignmentSlug: assignment.slug)
            }()

            return AssignmentRow(
                setupID: setupID,
                assignmentID: assignment?.publicID,
                title: assignment?.title,
                isOpen: assignment?.isOpen,
                dueAt: assignment?.dueAt.map { fmt.string(from: $0) },
                status: status,
                sortOrder: assignment?.sortOrder,
                validationStatus: validationStatus,
                validationSubmissionID: validationSubmissionID,
                suiteCount: suiteCount,
                createdAt: setup.createdAt.map { fmt.string(from: $0) } ?? "—",
                submittedStudentCount: assignment != nil ? (uniqueSubmittersBySetup[setupID] ?? 0) : nil,
                vanityURL: vanityURL
            )
        }
    }

    /// Sorts rows: published-with-sortOrder first (ascending), then
    /// published-without-sortOrder (in setup-creation order), then
    /// unpublished setups (in setup-creation order).
    func sortAssignmentRows(
        _ rows: [AssignmentRow],
        setupIndexByID: [String: Int]
    ) -> [AssignmentRow] {
        rows.sorted { lhs, rhs in
            let lhsPublished = lhs.assignmentID != nil
            let rhsPublished = rhs.assignmentID != nil
            if lhsPublished != rhsPublished {
                return lhsPublished && !rhsPublished
            }

            if lhsPublished && rhsPublished {
                switch (lhs.sortOrder, rhs.sortOrder) {
                case (let l?, let r?) where l != r:
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
    }

    /// Buckets sorted rows into per-section groups + a trailing
    /// "ungrouped" list for rows whose assignment has no `sectionID`
    /// (or whose `sectionID` no longer matches any section).
    func groupRowsBySection(
        sortedRows: [AssignmentRow],
        allSections: [APICourseSection],
        sectionByPublicID: [String: UUID]
    ) -> (sectionContexts: [CourseSectionRow], ungroupedRows: [AssignmentRow]) {
        var rowsBySectionID: [UUID: [AssignmentRow]] = [:]
        var ungroupedRows: [AssignmentRow] = []
        for row in sortedRows {
            if let aID = row.assignmentID, let sID = sectionByPublicID[aID] {
                rowsBySectionID[sID, default: []].append(row)
            } else {
                ungroupedRows.append(row)
            }
        }
        let sectionContexts = allSections.map { section -> CourseSectionRow in
            let sID = section.id ?? UUID()
            return CourseSectionRow(
                sectionID: sID.uuidString,
                name: section.name,
                defaultGradingMode: section.defaultGradingMode,
                sortOrder: section.sortOrder,
                rows: rowsBySectionID[sID] ?? []
            )
        }
        return (sectionContexts, ungroupedRows)
    }
}
