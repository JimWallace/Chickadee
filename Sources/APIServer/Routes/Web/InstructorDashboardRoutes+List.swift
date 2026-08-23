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
import SQLKit
import Vapor

// MARK: - Intermediate query results

/// Aggregated student-roster data for the active course.
/// `enrolledStudents` includes pending pre-enrollments at the tail.
struct CourseRosterData {
    let enrolledStudents: [EnrolledStudentRow]
    let enrolledStudentIDs: Set<UUID>
    let enrolledStudentCount: Int
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

    // MARK: - Roster

    /// Builds the enrolled-students table.  Only enrolled users with
    /// `role == "student"` count toward the numerators / denominators on the
    /// per-assignment "X / Y" badge — admin or instructor users enrolled for
    /// testing must not inflate the student-facing counters.  Pending
    /// CSV-uploaded pre-enrollments are shown as muted rows in the same table
    /// and are counted toward the "Y students enrolled" denominator.
    func buildCourseRoster(
        req: Request,
        activeCourseUUID: UUID,
        activeCourseCode: String,
        fmt: DateFormatter,
        isoFormatter: ISO8601DateFormatter
    ) async throws -> CourseRosterData {
        let (enrolledUsers, rolesByUserID) = try await loadEnrolledUsersForRoster(
            req: req, activeCourseUUID: activeCourseUUID)
        var enrolledStudents = buildEnrolledStudentRows(
            enrolledUsers: enrolledUsers,
            rolesByUserID: rolesByUserID,
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

        // The "Y students enrolled" denominator counts per-course students only
        // (TA/instructor/admin test accounts excluded), keyed off the enrollment
        // role now that the global student role is retired (#417 Slice G2).
        let activeStudentIDs = Set(
            enrolledUsers
                .compactMap(\.id)
                .filter { rolesByUserID[$0] == .student }
        )
        // Pending pre-enrollments are CSV-uploaded students who haven't
        // logged in yet — count them toward the "Y students enrolled"
        // denominator so the badge reflects the instructor's roster intent,
        // not just who's logged in.
        let enrolledStudentCount = activeStudentIDs.count + pendingPreEnrollments.count

        return CourseRosterData(
            enrolledStudents: enrolledStudents,
            enrolledStudentIDs: activeStudentIDs,
            enrolledStudentCount: enrolledStudentCount
        )
    }

    /// Enrolled-student rows + active-student count for the active course.
    /// Shared by the Students-tab page render and its polling endpoint.
    /// Mirrors `buildCourseRoster`: active enrollments first (last-seen-desc),
    /// pending CSV pre-enrollments appended as muted rows, with the count
    /// covering both.
    func loadEnrolledStudentRows(
        req: Request,
        activeCourseUUID: UUID,
        activeCourseCode: String,
        fmt: DateFormatter,
        isoFormatter: ISO8601DateFormatter
    ) async throws -> (rows: [EnrolledStudentRow], count: Int) {
        let (enrolledUsers, rolesByUserID) = try await loadEnrolledUsersForRoster(
            req: req, activeCourseUUID: activeCourseUUID)
        var rows = buildEnrolledStudentRows(
            enrolledUsers: enrolledUsers,
            rolesByUserID: rolesByUserID,
            activeCourseUUID: activeCourseUUID,
            activeCourseCode: activeCourseCode,
            fmt: fmt,
            isoFormatter: isoFormatter
        )
        let pendingPreEnrollments = try await APIPreEnrollment.query(on: req.db)
            .filter(\.$course.$id == activeCourseUUID)
            .sort(\.$username)
            .all()
        rows.append(
            contentsOf: buildPendingPreEnrollmentRows(
                pendingPreEnrollments: pendingPreEnrollments,
                activeCourseUUID: activeCourseUUID
            )
        )
        let activeStudentCount =
            enrolledUsers.compactMap(\.id).filter { rolesByUserID[$0] == .student }.count
        return (rows, activeStudentCount + pendingPreEnrollments.count)
    }

    /// Loads the enrolled users for the course, sorted last-seen-desc then
    /// username-asc.  Returns an empty array if no enrollments exist.
    private func loadEnrolledUsersForRoster(
        req: Request,
        activeCourseUUID: UUID
    ) async throws -> (users: [APIUser], rolesByUserID: [UUID: CourseRole]) {
        let enrollments = try await APICourseEnrollment.query(on: req.db)
            .filter(\.$course.$id == activeCourseUUID)
            .all()
        let enrolledUserIDs = enrollments.map(\.userID)
        guard !enrolledUserIDs.isEmpty else { return ([], [:]) }
        var rolesByUserID: [UUID: CourseRole] = [:]
        for enrollment in enrollments { rolesByUserID[enrollment.userID] = enrollment.role }
        let users = try await APIUser.query(on: req.db)
            .filter(\.$id ~~ enrolledUserIDs)
            // Exclude `mcp` service accounts: they may be enrolled to scope an
            // agent's access (admin MCP tab) but are not roster members.
            .filter(\.$role != UserRole.mcp.rawValue)
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
        return (users, rolesByUserID)
    }

    private func buildEnrolledStudentRows(
        enrolledUsers: [APIUser],
        rolesByUserID: [UUID: CourseRole],
        activeCourseUUID: UUID,
        activeCourseCode: String,
        fmt: DateFormatter,
        isoFormatter: ISO8601DateFormatter
    ) -> [EnrolledStudentRow] {
        enrolledUsers.compactMap { u in
            guard let id = u.id else { return nil }
            // Skip rows that somehow lack a urlToken instead of failing
            // the whole roster render — the invariant says every user has
            // one (init default + the historical backfill), so this
            // branch is unreachable in practice but kept for safety.
            guard let token = u.urlToken, !token.isEmpty else { return nil }
            return EnrolledStudentRow(
                id: id.uuidString,
                username: u.username,
                displayName: u.displayName ?? u.username,
                role: (rolesByUserID[id] ?? .student).rawValue,
                lastSeenAtText: u.lastSeenAt.map { fmt.string(from: $0) } ?? "—",
                lastSeenAtISO: u.lastSeenAt.map { isoFormatter.string(from: $0) },
                submissionsURL: studentSubmissionsURL(
                    courseCode: activeCourseCode,
                    urlToken: token
                ),
                unenrollURL: "/courses/\(activeCourseUUID.uuidString)/unenroll/\(id.uuidString)",
                isPending: false,
                registerURL: ""
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
                isPending: true,
                registerURL:
                    "/courses/\(activeCourseUUID.uuidString)/pre-enroll/\(preID.uuidString)/register"
            )
        }
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

        // Grouped COUNT(DISTINCT user_id) instead of loading every matching
        // submission row and building per-setup sets in Swift — this runs on
        // the instructor landing page and degrades linearly with term volume
        // (June 2026 audit, P1.6; same pattern as the admin runner counts).
        if let sql = req.db as? SQLDatabase {
            struct SubmitterCountRow: Decodable {
                let testSetupID: String
                let submitters: Int
                enum CodingKeys: String, CodingKey {
                    case testSetupID = "test_setup_id"
                    case submitters
                }
            }
            let rows = try await sql.select()
                .column("test_setup_id")
                .column(
                    SQLFunction("COUNT", args: SQLDistinct(SQLColumn("user_id"))), as: "submitters"
                )
                .from("submissions")
                .where("test_setup_id", .in, allSetupIDs)
                .where("kind", .equal, APISubmission.Kind.student)
                // Bind UUIDs (not strings) so the Postgres uuid column and the
                // SQLite text storage both compare correctly.
                .where("user_id", .in, Array(enrolledStudentIDs))
                .groupBy("test_setup_id")
                .all(decoding: SubmitterCountRow.self)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.testSetupID, $0.submitters) })
        }

        // Non-SQL fallback (not hit by the sqlite/postgres drivers in use).
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

    // MARK: - Validation-variant summaries

    /// Aggregates each setup's current validation-variant batch (multi-variant
    /// validation) for the listing: one query for the whole page, grouped in
    /// memory — the batches are `validationVariantCount` rows per setup.
    func loadValidationVariantSummaries(
        req: Request, allSetupIDs: [String]
    ) async throws -> [String: ValidationVariantSummary] {
        guard !allSetupIDs.isEmpty else { return [:] }
        let variants = try await ValidationVariant.query(on: req.db)
            .filter(\.$testSetupID ~~ allSetupIDs)
            .sort(\.$variantIndex)
            .all()
        var bySetup: [String: [ValidationVariant]] = [:]
        for variant in variants {
            bySetup[variant.testSetupID, default: []].append(variant)
        }
        return bySetup.mapValues { batch in
            ValidationVariantSummary(
                total: batch.count,
                failed: batch.count { $0.status == ValidationVariant.Status.failed },
                pending: batch.count { $0.status == ValidationVariant.Status.pending },
                firstFailedSubmissionID: batch.first {
                    $0.status == ValidationVariant.Status.failed && $0.submissionID != nil
                }?.submissionID)
        }
    }

    // MARK: - Row construction

    /// Builds an `AssignmentRow` for each setup, joining the matching
    /// assignment (if any) and computing the suite count, status, and
    /// vanity URL.
    func buildAssignmentRows(
        allSetups: [APITestSetup],
        assignmentBySetup: [String: APIAssignment],
        uniqueSubmittersBySetup: [String: Int],
        variantSummariesBySetup: [String: ValidationVariantSummary],
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
                status = a.visibility.rawValue  // "closed" | "preview" | "open"
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

            let variants = variantSummariesBySetup[setupID]

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
                variantState: variants?.state ?? "none",
                variantSummaryText: variants?.summaryText ?? "",
                failedVariantSubmissionID: variants?.firstFailedSubmissionID,
                suiteCount: suiteCount,
                createdAt: setup.createdAt.map { fmt.string(from: $0) } ?? "—",
                submittedStudentCount: assignment != nil ? (uniqueSubmittersBySetup[setupID] ?? 0) : nil,
                vanityURL: vanityURL
            )
        }
    }

    /// Interleaves each section's assignment lane and content lane into one
    /// ordered `items` list, and produces the trailing ungrouped bucket the same
    /// way. Within a section (which only ever holds published assignments, since
    /// an unpublished draft has no `sectionID`) the two lanes merge by their
    /// shared `sort_order` (`mergedBySectionItemOrder`). The ungrouped bucket
    /// merges published assignments + content the same way, then appends
    /// unpublished drafts (in setup-creation order) so drafts stay at the bottom.
    /// Every section is emitted even when empty, so a content-only section still
    /// renders.
    func buildInstructorSectionItems(
        assignmentRows: [AssignmentRow],
        contentItems: [APICourseContentItem],
        allSections: [APICourseSection],
        sectionByPublicID: [String: UUID],
        setupByID: [String: APITestSetup],
        setupIndexByID: [String: Int]
    ) -> (sectionContexts: [CourseSectionRow], ungroupedItems: [InstructorSectionItem]) {
        typealias Keyed = (key: SectionItemSortKey, item: InstructorSectionItem)
        let liveSectionIDs = Set(allSections.compactMap(\.id))
        var keyedBySectionID: [UUID: [Keyed]] = [:]
        var ungroupedKeyed: [Keyed] = []
        var ungroupedUnpublished: [(index: Int, row: AssignmentRow)] = []

        func assignmentKey(_ row: AssignmentRow) -> SectionItemSortKey {
            SectionItemSortKey(
                sortOrder: row.sortOrder,
                createdAt: setupByID[row.setupID]?.createdAt,
                stableID: row.setupID)
        }
        for row in assignmentRows {
            if let aID = row.assignmentID, let sID = sectionByPublicID[aID], liveSectionIDs.contains(sID) {
                keyedBySectionID[sID, default: []].append((assignmentKey(row), .assignment(row)))
            } else if row.assignmentID != nil {
                ungroupedKeyed.append((assignmentKey(row), .assignment(row)))
            } else {
                // Unpublished draft: no section, always sorted after the merged
                // published/content items, by setup-creation order.
                ungroupedUnpublished.append((setupIndexByID[row.setupID] ?? Int.max, row))
            }
        }
        for item in contentItems {
            let keyed: Keyed = (
                SectionItemSortKey(
                    sortOrder: item.sortOrder, createdAt: item.createdAt,
                    stableID: item.id?.uuidString ?? ""),
                .material(ContentItemRow(from: item))
            )
            if let sID = item.sectionID, liveSectionIDs.contains(sID) {
                keyedBySectionID[sID, default: []].append(keyed)
            } else {
                ungroupedKeyed.append(keyed)
            }
        }

        let sectionContexts = allSections.map { section -> CourseSectionRow in
            let sID = section.id ?? UUID()
            return CourseSectionRow(
                sectionID: sID.uuidString,
                name: section.name,
                defaultGradingMode: section.defaultGradingMode,
                sortOrder: section.sortOrder,
                items: mergedBySectionItemOrder(keyedBySectionID[sID] ?? [])
            )
        }

        var ungroupedItems = mergedBySectionItemOrder(ungroupedKeyed)
        ungroupedItems +=
            ungroupedUnpublished
            .sorted { $0.index < $1.index }
            .map { InstructorSectionItem.assignment($0.row) }
        return (sectionContexts, ungroupedItems)
    }

    /// Content items for the active course, in lane order. The instructor
    /// dashboard shows all items (published and hidden drafts alike).
    func loadCourseContentItems(
        req: Request,
        activeCourseUUID: UUID?
    ) async throws -> [APICourseContentItem] {
        guard let activeCourseUUID else { return [] }
        return try await APICourseContentItem.query(on: req.db)
            .filter(\.$courseID == activeCourseUUID)
            .sort(\.$sortOrder, .ascending)
            .all()
    }
}
