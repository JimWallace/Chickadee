// APIServer/Routes/Web/WebRoutes+IndexRows.swift
//
// The student dashboard's heavy phases, extracted from `WebRoutes.index`
// (#1120 — it was the route layer's last >100-line handler, carrying a
// SwiftLint suppression): the per-student grade/submission/badge data load
// and the per-setup row build. `index` keeps the page-state dispatch and the
// load → sort → group pipeline.

import Core
import Fluent
import Foundation
import Vapor

/// The per-student maps the dashboard rows read: latest submission, count,
/// best grade ("highest grade wins", #1111), instructor override, and the
/// latest-submission badges, all keyed by test-setup id. Empty for an
/// anonymous/edge state (`user.id == nil`) or a course with no setups.
struct DashboardGradeData {
    var latestSubmissionBySetupID: [String: LatestSubmissionItem] = [:]
    var submissionCountBySetupID: [String: Int] = [:]
    var bestGradePercentBySetupID: [String: Int] = [:]
    var overridePercentBySetupID: [String: Int] = [:]
    var latestBadgesBySetupID: [String: [AchievementBadge]] = [:]
}

/// Everything `buildTestSetupRow` reads besides the setup itself — computed
/// once per request, shared across every row (mirrors
/// `StudentAssignmentRowContext` on the per-student page).
struct IndexRowContext {
    let fmt: DateFormatter
    let assignmentBySetup: [String: APIAssignment]
    let gradeData: DashboardGradeData
    let extensionDueAtBySetupID: [String: Date]
    let previouslyOpenedSetupIDs: Set<String>
    let isActiveCourseStaff: Bool
    let activeCourseCode: String?
    let hasNotebookBySetupID: [String: Bool]
}

extension WebRoutes {

    /// Loads the viewer's grade/submission/badge maps for the dashboard —
    /// overrides + submissions concurrently, then the result/achievement
    /// phase (`applyResultDerivedData`).
    static func loadStudentDashboardGradeData(
        req: Request, user: APIUser, setups: [APITestSetup], fmt: DateFormatter
    ) async throws -> DashboardGradeData {
        var data = DashboardGradeData()
        guard let userID = user.id else { return data }
        let setupIDs = setups.compactMap(\.id)
        guard !setupIDs.isEmpty else { return data }

        // Instructor grade overrides for this student take precedence over
        // the runner-computed best grade.  The override and submission reads
        // are independent and run concurrently.
        async let overridesFetch = loadGradeOverridePercents(setupIDs: setupIDs, on: req.db)
        async let submissionsFetch = APISubmission.query(on: req.db)
            .filter(\.$userID == userID)
            .filter(\.$testSetupID ~~ setupIDs)
            .filter(\.$kind == APISubmission.Kind.student)
            .sort(\.$submittedAt, .descending)
            .all()
        let overrideMap = try await overridesFetch
        for setupID in setupIDs {
            if let pct = overrideMap[GradeOverrideKey(setupID: setupID, userID: userID)] {
                data.overridePercentBySetupID[setupID] = pct
            }
        }
        let submissions = try await submissionsFetch

        var grouped: [String: [APISubmission]] = [:]
        for submission in submissions {
            grouped[submission.testSetupID, default: []].append(submission)
        }
        for (setupID, items) in grouped {
            data.submissionCountBySetupID[setupID] = items.count
            if let latest = items.first {
                let when = latest.submittedAt.map { fmt.string(from: $0) } ?? "—"
                data.latestSubmissionBySetupID[setupID] = LatestSubmissionItem(
                    submissionID: latest.id ?? "",
                    submittedAtText: when
                )
            }
        }

        try await applyResultDerivedData(
            req: req, userID: userID, setupIDs: setupIDs,
            submissions: submissions, grouped: grouped, data: &data)
        return data
    }

    /// The result-derived phase of the grade-data load: best grade per setup
    /// ("highest grade wins", #1111), latest-submission badges, and the class
    /// badges this user holds.  No-op when the student has no submissions.
    private static func applyResultDerivedData(
        req: Request, userID: UUID, setupIDs: [String],
        submissions: [APISubmission], grouped: [String: [APISubmission]],
        data: inout DashboardGradeData
    ) async throws {
        let submissionIDs = submissions.compactMap(\.id)
        guard !submissionIDs.isEmpty else { return }
        // Results plus the three achievement reads only share inputs computed
        // by the caller, so all four run concurrently.
        async let resultsFetch = APIResult.query(on: req.db)
            .filter(\.$submissionID ~~ submissionIDs)
            .sort(\.$receivedAt, .descending)
            .all()
        async let disabledFetch = BuiltInAchievements.disabledBySetup(
            setupIDs: setupIDs, on: req.db)
        async let perSubFetch = BuiltInAchievements.manifestPerSubmissionBySetup(
            setupIDs: setupIDs, on: req.db)
        // Class-wide badges this user currently holds across all setups.
        async let classAchievementsFetch = APIClassAchievement.query(on: req.db)
            .filter(\.$userID == userID)
            .filter(\.$testSetupID ~~ setupIDs)
            .all()
        let resultRows = try await resultsFetch

        // Best grade percentage per submission across ALL result sources —
        // the shared "highest grade wins" fold applied to the rows we
        // already fetched (#1111).
        var resultsBySubmissionID: [String: [APIResult]] = [:]
        for row in resultRows {
            resultsBySubmissionID[row.submissionID, default: []].append(row)
        }
        let bestPercentBySubmissionID =
            resultsBySubmissionID
            .compactMapValues { bestGradePercent(of: $0) }
        let preferredResultBySubmissionID = preferredResultsWorkerFirst(resultRows)

        for submission in submissions {
            guard let subID = submission.id,
                let gradePercent = bestPercentBySubmissionID[subID]
            else { continue }
            let setupID = submission.testSetupID
            if gradePercent > (data.bestGradePercentBySetupID[setupID] ?? 0) {
                data.bestGradePercentBySetupID[setupID] = gradePercent
            }
        }

        let disabledBySetup = try await disabledFetch
        let perSubBySetup = try await perSubFetch
        for (setupID, latest) in data.latestSubmissionBySetupID {
            if let badges = latestSubmissionBadges(
                setupID: setupID, latest: latest, grouped: grouped,
                preferredResultBySubmissionID: preferredResultBySubmissionID,
                perSubmission: perSubBySetup[setupID],
                disabled: disabledBySetup[setupID] ?? [])
            {
                data.latestBadgesBySetupID[setupID] = badges
            }
        }

        let classAchievements = try await classAchievementsFetch
        for ach in classAchievements {
            if let badge = AchievementBadge.forClassAchievement(
                ach.achievementID, disabled: disabledBySetup[ach.testSetupID] ?? [])
            {
                data.latestBadgesBySetupID[ach.testSetupID, default: []].append(badge)
            }
        }
    }

    /// One preferred result per submission, worker-first — the browser result
    /// is only the fallback while the worker regrade is queued.
    private static func preferredResultsWorkerFirst(
        _ rows: [APIResult]
    ) -> [String: APIResult] {
        var preferred: [String: APIResult] = [:]
        for row in rows {
            let key = row.submissionID
            if let existing = preferred[key] {
                let existingSource = existing.source ?? "worker"
                let currentSource = row.source ?? "worker"
                if existingSource == "worker" { continue }
                if currentSource == "worker" {
                    preferred[key] = row
                }
            } else {
                preferred[key] = row
            }
        }
        return preferred
    }

    /// The per-submission badges for one setup's latest submission, or nil
    /// when it has no decodable graded result.
    private static func latestSubmissionBadges(
        setupID: String,
        latest: LatestSubmissionItem,
        grouped: [String: [APISubmission]],
        preferredResultBySubmissionID: [String: APIResult],
        perSubmission: [Achievement]?,
        disabled: Set<String>
    ) -> [AchievementBadge]? {
        guard
            let latestSubmission = grouped[setupID]?.first(where: { $0.id == latest.submissionID }),
            let result = preferredResultBySubmissionID[latest.submissionID],
            let collection = decodedCollection(from: result.collectionJSON),
            let gradePercent = gradePercent(from: collection)
        else { return nil }
        let latestAttempt = latestSubmission.attemptNumber ?? 1
        let priorSub = grouped[setupID]?.first(where: { $0.attemptNumber == latestAttempt - 1 })
        let priorGradePercent: Int? = priorSub.flatMap { ps in
            guard let psID = ps.id,
                let pr = preferredResultBySubmissionID[psID]
            else { return nil }
            return pr.gradePercentValue
        }
        return AchievementBadge.forSubmission(
            BadgeContext(
                attemptNumber: latestAttempt,
                gradePercent: gradePercent,
                executionTimeMs: collection.executionTimeMs,
                priorGradePercent: priorGradePercent
            ),
            achievements: perSubmission,
            disabled: disabled)
    }

    /// Builds one dashboard row from a setup plus the request-wide context.
    static func buildTestSetupRow(setup: APITestSetup, context: IndexRowContext) -> TestSetupRow {
        let setupID = setup.id ?? ""
        let data = Data(setup.manifest.utf8)
        let props = decodeManifest(from: data)
        let assignment = context.assignmentBySetup[setupID]
        let latestSubmission = context.gradeData.latestSubmissionBySetupID[setupID]
        let submissionCount = context.gradeData.submissionCountBySetupID[setupID] ?? 0
        // A future open date drives the "Opens …" hint in the Due column,
        // but not a distinct status — every assignment is scheduled, so a
        // "scheduled" badge would add no signal.
        let notYetOpen: Bool = {
            guard let assignment, let startsAt = assignment.startsAt else { return false }
            return Date() < startsAt
        }()
        // Preview is staff-only: staff see it functioning as "open" with a
        // subtle staff-only marker, while to students it is indistinguishable
        // from "closed". So the displayed status is resolved per viewer.
        let status: String
        let staffOnly: Bool
        if let assignment {
            switch assignment.visibility {
            case .open:
                status = "open"
                staffOnly = false
            case .closed:
                status = "closed"
                staffOnly = false
            case .preview:
                status = context.isActiveCourseStaff ? "open" : "closed"
                staffOnly = context.isActiveCourseStaff
            }
        } else {
            status = "unpublished"
            staffOnly = false
        }
        // True when the setup has a flat notebook file on disk, or the zip
        // contains at least one .ipynb entry (resolved above via the cache).
        let hasNotebook = context.hasNotebookBySetupID[setupID] ?? false
        let vanityBaseURL: String? = {
            guard let assignment,
                let courseCode = context.activeCourseCode,
                !courseCode.isEmpty,
                !assignment.slug.isEmpty
            else { return nil }
            return VanityURLRoutes.vanityPath(courseCode: courseCode, assignmentSlug: assignment.slug)
        }()
        // Active extension for this student on this assignment.  Drives
        // the Submit button and Due column when the assignment-wide
        // deadline has passed but this user retains submit privileges.
        let extensionDueAt = context.extensionDueAtBySetupID[setupID]
        let baselineDueAt = assignment?.dueAt
        let hasActiveExtension = studentHasActiveExtension(extensionDueAt: extensionDueAt)
        let effectiveDueAt = laterDeadline(
            baseline: baselineDueAt, extensionDueAt: extensionDueAt)
        let isOpenForThisUser: Bool = {
            guard let assignment else { return false }
            // Preview is open for staff, closed for students; staff testing a
            // preview also bypass the future-open-date gate (see submissionGate).
            let gate = assignment.visibility.submissionGate(isStaff: context.isActiveCourseStaff)
            return isAssignmentOpenForUser(
                isOpen: gate.treatAsOpen,
                overrideActive: assignment.deadlineOverrideActive ?? false,
                baselineDueAt: baselineDueAt,
                effectiveDueAt: effectiveDueAt,
                hasActiveExtension: hasActiveExtension,
                startsAt: gate.honorsStartDate ? assignment.startsAt : nil
            )
        }()
        // A published-but-closed assignment is openable read-only, so it
        // still gets the open-notebook action even for a student who never
        // engaged with it (the page renders read-only and hides Submit).
        let canEdit =
            isOpenForThisUser
            || context.previouslyOpenedSetupIDs.contains(setupID)
            || (assignment.map { assignmentVisibleToStudentByState($0) } ?? false)
        // An active per-student extension keeps a class-closed assignment
        // open for this one student, so the dashboard badge should read as
        // actionable ("extended") rather than the misleading class-wide
        // "closed" — the more so on phones, where the due column (with its
        // "(extension)" note) is hidden and the badge is the only status
        // signal. Scoped to the genuine published-then-closed case; preview /
        // unpublished are untouched, and staff never carry extensions.
        let displayStatus = (hasActiveExtension && status == "closed") ? "extended" : status
        let badgeSplit = AchievementBadge.dashboardSplit(context.gradeData.latestBadgesBySetupID[setupID] ?? [])
        return TestSetupRow(
            id: setupID,
            title: assignment?.title,
            notebookURL: vanityBaseURL ?? "/testsetups/\(setupID)/notebook",
            submitURL: vanityBaseURL.map { "\($0)/submit" } ?? "/testsetups/\(setupID)/submit",
            historyURL: vanityBaseURL.map { "\($0)/history" } ?? "/testsetups/\(setupID)/history",
            suiteCount: props?.testSuites.count ?? 0,
            createdAt: setup.createdAt.map { context.fmt.string(from: $0) } ?? "—",
            dueAt: assignment?.dueAt.map { context.fmt.string(from: $0) },
            opensAtText: notYetOpen ? assignment?.startsAt.map { context.fmt.string(from: $0) } : nil,
            status: displayStatus,
            staffOnly: staffOnly,
            isOpen: isOpenForThisUser,
            canEdit: canEdit,
            gradingMode: props?.gradingMode.rawValue ?? GradingMode.worker.rawValue,
            hasNotebook: hasNotebook,
            submissionCount: submissionCount,
            hasLatestSubmission: latestSubmission != nil,
            latestSubmissionID: latestSubmission?.submissionID ?? "",
            latestSubmittedAtText: latestSubmission?.submittedAtText ?? "—",
            additionalSubmissionCount: max(submissionCount - 1, 0),
            bestGradeText: context.gradeData.overridePercentBySetupID[setupID].map { "\($0)%" }
                ?? context.gradeData.bestGradePercentBySetupID[setupID].map { "\($0)%" },
            gradeIsOverridden: context.gradeData.overridePercentBySetupID[setupID] != nil,
            badges: badgeSplit.visible,
            extraBadgeCount: badgeSplit.extraCount,
            extraBadgesTooltip: badgeSplit.extraTooltip,
            hasActiveExtension: hasActiveExtension,
            effectiveDueAtText: effectiveDueAt.map { context.fmt.string(from: $0) }
        )
    }
}
