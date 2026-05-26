// APIServer/Routes/Web/InstructorDashboardRoutes+BrightSpace.swift
//
// The instructor BrightSpace tab: connection status, the assignment→grade-
// item mapping, the sync-activity log, manual sync actions, and unmapped-
// student diagnostics.  Everything here is scoped to the active course.
//
// Connection credentials are server-level (env, ops-managed) and never
// exposed here; the course→org-unit binding is admin-set on the course page.
// This tab is where an instructor wires grade items and watches grades flow.
//
//   GET  /instructor/brightspace                       → instructor-brightspace.leaf
//   POST /instructor/brightspace/test                  → whoami connection test (JSON)
//   GET  /instructor/brightspace/grade-objects         → [BrightSpaceGradeObject] (dropdown)
//   POST /instructor/brightspace/sync-now              → run a sweep immediately
//   POST /instructor/brightspace/retry-failed          → re-queue errored pushes
//   POST /instructor/:assignmentID/brightspace/push-all → re-push every grade for one assignment

import Core
import Fluent
import Foundation
import Vapor

extension InstructorDashboardRoutes {

    // MARK: - GET /instructor/brightspace

    @Sendable
    func brightspacePage(req: Request) async throws -> View {
        let user = try req.auth.require(APIUser.self)
        let ctx = try await buildBrightspaceContext(req: req, user: user)
        return try await req.view.render("instructor-brightspace", ctx)
    }

    // MARK: - POST /instructor/brightspace/test

    /// Validates the configured BrightSpace credentials via D2L `whoami`.
    /// Returns JSON the panel renders inline — surfaces auth problems before
    /// any grade push fails.
    @Sendable
    func brightspaceTestConnection(req: Request) async throws -> BrightspaceTestResult {
        guard let client = req.application.brightSpaceClient else {
            return BrightspaceTestResult(ok: false, message: "BrightSpace is not configured on this server.")
        }
        do {
            let who = try await client.whoami(on: req.application)
            let who2 = who.uniqueName.isEmpty ? who.displayName : "\(who.displayName) (\(who.uniqueName))"
            return BrightspaceTestResult(ok: true, message: "Connected as \(who2).")
        } catch {
            return BrightspaceTestResult(ok: false, message: "Connection failed: \(error.localizedDescription)")
        }
    }

    // MARK: - GET /instructor/brightspace/grade-objects

    /// Lists the active course's D2L grade items for the mapping dropdown.
    /// Returns an empty array when sync is unconfigured or the course isn't
    /// bound — the panel falls back to free-text entry in that case.
    @Sendable
    func brightspaceGradeObjects(req: Request) async throws -> [BrightSpaceGradeObject] {
        let user = try req.auth.require(APIUser.self)
        guard let client = req.application.brightSpaceClient else { return [] }
        let courseState = try await req.resolveActiveCourse(for: user)
        guard let courseUUID = courseState.activeCourseUUID,
            let course = try await APICourse.find(courseUUID, on: req.db),
            let orgUnitID = course.brightspaceOrgUnitID, !orgUnitID.isEmpty
        else { return [] }
        do {
            return try await client.listGradeObjects(orgUnitID: orgUnitID, on: req.application)
        } catch {
            req.logger.warning("BrightSpace grade-objects fetch failed: \(error)")
            return []
        }
    }

    // MARK: - POST /instructor/brightspace/sync-now

    @Sendable
    func brightspaceSyncNow(req: Request) async throws -> Response {
        await runImmediateBrightspaceSweep(req: req)
        return req.redirect(to: "/instructor/brightspace")
    }

    // MARK: - POST /instructor/brightspace/retry-failed

    @Sendable
    func brightspaceRetryFailed(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)
        if let courseUUID = courseState.activeCourseUUID {
            let setupIDs = try await courseStudentResultIDs(req: req, courseUUID: courseUUID)
            let results =
                setupIDs.isEmpty
                ? []
                : try await APIResult.query(on: req.db)
                    .filter(\.$submissionID ~~ setupIDs)
                    .all()
            for result in results where (result.brightspaceSyncError ?? "").isEmpty == false {
                result.brightspaceSyncPending = true
                result.brightspacePendingSince = Date.distantPast
                result.brightspaceSyncError = nil
                try await result.save(on: req.db)
            }
        }
        await runImmediateBrightspaceSweep(req: req)
        return req.redirect(to: "/instructor/brightspace")
    }

    // MARK: - POST /instructor/:assignmentID/brightspace/push-all

    /// Re-queues every student's grade for one assignment, then sweeps — the
    /// end-of-term / first-time backfill button.
    @Sendable
    func brightspacePushAllForAssignment(req: Request) async throws -> Response {
        let idStr = try assignmentPublicIDParameter(from: req)
        guard let assignment = try await assignmentByPublicID(idStr, on: req.db) else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(idStr)'")
        }
        let submissionIDs = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == assignment.testSetupID)
            .filter(\.$kind == APISubmission.Kind.student)
            .all()
            .compactMap(\.id)
        let results =
            submissionIDs.isEmpty
            ? []
            : try await APIResult.query(on: req.db)
                .filter(\.$submissionID ~~ submissionIDs)
                .all()
        for result in results {
            result.brightspaceSyncPending = true
            result.brightspacePendingSince = Date.distantPast
            result.brightspaceSyncError = nil
            try await result.save(on: req.db)
        }
        await runImmediateBrightspaceSweep(req: req)
        return req.redirect(to: "/instructor/brightspace")
    }

    // MARK: - Helpers

    /// Submission IDs (used as result-query keys) for all student submissions
    /// in the active course's test setups.
    private func courseStudentResultIDs(req: Request, courseUUID: UUID) async throws -> [String] {
        let setupIDs = try await APIAssignment.query(on: req.db)
            .filter(\.$courseID == courseUUID)
            .all()
            .map(\.testSetupID)
        guard !setupIDs.isEmpty else { return [] }
        return try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID ~~ Array(Set(setupIDs)))
            .filter(\.$kind == APISubmission.Kind.student)
            .all()
            .compactMap(\.id)
    }

    /// Runs a grade-sync sweep immediately, bypassing the debounce window so
    /// a manual "Sync now" click pushes everything currently pending.  No-op
    /// when BrightSpace isn't configured.
    private func runImmediateBrightspaceSweep(req: Request) async {
        guard let client = req.application.brightSpaceClient,
            let config = req.application.brightSpaceSyncConfig
        else { return }
        // Pass a future `now` so the debounce cutoff lands ahead of every
        // pending row, forcing an immediate push instead of waiting out the
        // window.
        _ = try? await sweepBrightSpaceGradeSync(
            on: req.db,
            client: client,
            config: config,
            logger: req.logger,
            application: req.application,
            now: Date().addingTimeInterval(config.debounceSecs + 1)
        )
    }

    /// Assembles the full BrightSpace-tab context for the active course.
    private func buildBrightspaceContext(
        req: Request, user: APIUser
    ) async throws
        -> InstructorBrightspaceContext
    {
        let courseState = try await req.resolveActiveCourse(for: user)
        let userContext = CurrentUserContext(
            user: user, activeCourse: courseState.active, enrolledCourses: courseState.all)
        let syncEnabled = req.application.brightSpaceClient != nil

        guard let courseUUID = courseState.activeCourseUUID,
            let course = try await APICourse.find(courseUUID, on: req.db)
        else {
            return InstructorBrightspaceContext(
                currentUser: userContext, activeInstructorTab: "brightspace",
                hasActiveCourse: courseState.active != nil, courseIsArchived: false,
                brightspaceSyncEnabled: syncEnabled, courseLinked: false,
                orgUnitID: nil, orgUnitName: nil,
                assignmentRows: [], hasAssignments: false,
                logRows: [], hasLog: false,
                summary: BrightspaceSyncSummary(synced: 0, pending: 0, errored: 0, unmapped: 0),
                unmappedStudents: [], hasUnmapped: false)
        }

        let orgUnitID = course.brightspaceOrgUnitID
        let courseLinked = !(orgUnitID ?? "").isEmpty
        let fmt = waterlooDateTimeFormatter()

        // Assignments, sorted to match the dashboard ordering.
        let assignments = try await APIAssignment.query(on: req.db)
            .filter(\.$courseID == courseUUID)
            .all()
            .sorted { lhs, rhs in
                switch (lhs.sortOrder, rhs.sortOrder) {
                case (let l?, let r?) where l != r: return l < r
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
            }
        let setupIDs = Array(Set(assignments.map(\.testSetupID)))

        // Recent log rows for this course (most recent first, capped).
        let logModels = try await APIBrightSpaceSyncLog.query(on: req.db)
            .filter(\.$courseID == courseUUID)
            .sort(\.$attemptedAt, .descending)
            .range(..<50)
            .all()

        // Latest log per test setup → per-assignment status badge.
        var latestBySetup: [String: APIBrightSpaceSyncLog] = [:]
        for log in logModels where latestBySetup[log.testSetupID] == nil {
            latestBySetup[log.testSetupID] = log
        }

        let assignmentRows = assignments.map { a -> BrightspaceAssignmentRow in
            let last = latestBySetup[a.testSetupID]
            return BrightspaceAssignmentRow(
                assignmentID: a.publicID,
                title: a.title,
                gradeObjectID: a.brightspaceGradeObjectID ?? "",
                lastSyncText: last?.attemptedAt.map { fmt.string(from: $0) } ?? "—",
                lastSyncStatus: last?.status ?? "none",
                lastSyncDetail: last?.detail)
        }

        let logRows = logModels.map { log -> BrightspaceLogRow in
            BrightspaceLogRow(
                attemptedAt: log.attemptedAt.map { fmt.string(from: $0) } ?? "—",
                username: log.username,
                assignmentTitle: log.assignmentTitle,
                points: log.points.map { String(format: "%.1f", $0) } ?? "—",
                status: log.status,
                detail: log.detail)
        }

        let (summary, unmapped) = try await brightspaceSummaryAndUnmapped(
            req: req, courseUUID: courseUUID, setupIDs: setupIDs, logModels: logModels)

        return InstructorBrightspaceContext(
            currentUser: userContext, activeInstructorTab: "brightspace",
            hasActiveCourse: true, courseIsArchived: course.isArchived,
            brightspaceSyncEnabled: syncEnabled, courseLinked: courseLinked,
            orgUnitID: orgUnitID, orgUnitName: course.brightspaceOrgUnitName,
            assignmentRows: assignmentRows, hasAssignments: !assignmentRows.isEmpty,
            logRows: logRows, hasLog: !logRows.isEmpty,
            summary: summary, unmappedStudents: unmapped, hasUnmapped: !unmapped.isEmpty)
    }

    /// Computes the summary counts (synced / pending / errored) from result
    /// rows and the unmapped-student list (no D2L account resolvable).
    private func brightspaceSummaryAndUnmapped(
        req: Request,
        courseUUID: UUID,
        setupIDs: [String],
        logModels: [APIBrightSpaceSyncLog]
    ) async throws -> (BrightspaceSyncSummary, [BrightspaceUnmappedStudentRow]) {
        // Result-level sync state across the course's student submissions.
        let submissionIDs =
            setupIDs.isEmpty
            ? []
            : try await APISubmission.query(on: req.db)
                .filter(\.$testSetupID ~~ setupIDs)
                .filter(\.$kind == APISubmission.Kind.student)
                .all()
                .compactMap(\.id)
        let results =
            submissionIDs.isEmpty
            ? []
            : try await APIResult.query(on: req.db)
                .filter(\.$submissionID ~~ submissionIDs)
                .all()
        var synced = 0
        var pending = 0
        var errored = 0
        for result in results {
            if result.brightspaceSyncPending == true { pending += 1 }
            if (result.brightspaceSyncError ?? "").isEmpty == false {
                errored += 1
            } else if result.brightspaceSyncedAt != nil {
                synced += 1
            }
        }

        // Unmapped students: enrolled students with no usable D2L identity.
        let enrolledUserIDs = try await APICourseEnrollment.query(on: req.db)
            .filter(\.$course.$id == courseUUID)
            .all()
            .map(\.userID)
        let students =
            enrolledUserIDs.isEmpty
            ? []
            : try await APIUser.query(on: req.db)
                .filter(\.$id ~~ enrolledUserIDs)
                .filter(\.$role == "student")
                .sort(\.$username)
                .all()
        let noAccountUsernames = Set(
            logModels
                .filter {
                    $0.status == APIBrightSpaceSyncLog.Status.skipped.rawValue
                        && ($0.detail?.contains("No BrightSpace account") ?? false)
                }
                .map(\.username))
        var unmapped: [BrightspaceUnmappedStudentRow] = []
        for student in students {
            let sid = student.studentID ?? ""
            if sid.isEmpty {
                unmapped.append(
                    BrightspaceUnmappedStudentRow(
                        username: student.username,
                        displayName: student.displayName ?? student.username,
                        reason: "No student/org-defined ID on file"))
            } else if noAccountUsernames.contains(student.username) {
                unmapped.append(
                    BrightspaceUnmappedStudentRow(
                        username: student.username,
                        displayName: student.displayName ?? student.username,
                        reason: "Not found in BrightSpace"))
            }
        }

        let summary = BrightspaceSyncSummary(
            synced: synced, pending: pending, errored: errored, unmapped: unmapped.count)
        return (summary, unmapped)
    }
}

/// JSON payload for the connection-test button.
struct BrightspaceTestResult: Content {
    let ok: Bool
    let message: String
}
