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

/// The viewer's slip-day state for the active course (#1228), loaded once per
/// dashboard request.  `.disabled` (the default) renders nothing: policy off,
/// staff viewer, or no active course.
struct DashboardSlipDayData {
    let policy: SlipDayPolicy
    /// Remaining balance (can go negative after a staff claw-back; display
    /// sites clamp at 0).
    let balance: Int
    /// Budget + per-student adjustment — the "of N" in "1 of N remaining".
    let totalBudget: Int
    /// Unrefunded spends per test setup, for the per-row offer state.
    let spendCountBySetupID: [String: Int]

    static let disabled = DashboardSlipDayData(
        policy: SlipDayPolicy.resolve(enabled: false, daysPerStudent: nil, extensionHours: nil),
        balance: 0,
        totalBudget: 0,
        spendCountBySetupID: [:]
    )

    /// "Slip days: 1 of 2 remaining." under the course heading; nil hides
    /// the line (policy off / staff / no course).  The balance clamps at 0
    /// for display — a negative value (staff claw-back beyond the unspent
    /// remainder) reads as an implementation detail, not a debt.
    var summaryLine: String? {
        policy.enabled
            ? "\(max(balance, 0)) of \(totalBudget) slip days"
            : nil
    }
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
    let slipDay: DashboardSlipDayData
}

/// The dashboard row's status badge and staff-only marker, resolved per viewer.
///
/// Preview is staff-only: staff see it functioning as "open" with a subtle
/// staff-only marker, while to a student it is indistinguishable from
/// "closed" — so this cannot be read off `visibility` alone.
func dashboardRowStatus(
    assignment: APIAssignment?, isActiveCourseStaff: Bool
) -> (status: String, staffOnly: Bool) {
    guard let assignment else { return ("unpublished", false) }
    switch assignment.visibility {
    case .open: return ("open", false)
    case .closed: return ("closed", false)
    case .preview:
        return (isActiveCourseStaff ? "open" : "closed", isActiveCourseStaff)
    }
}

/// The four gates the dashboard's Actions cell renders, derived once per row.
///
/// They live here, rather than as conditions spelled out in `index.leaf`,
/// because the cell also has to know whether it is offering *anything* — and
/// two copies of the same conditions eventually disagree, rendering a dash
/// beside live buttons or buttons beside a dash.
struct DashboardRowActionGates {
    let edit: Bool
    let upload: Bool
    let resetNotebook: Bool
    let slipDay: Bool

    /// True when the row offers at least one action.
    var any: Bool { edit || upload || resetNotebook || slipDay }
}

func dashboardRowActionGates(
    props: TestProperties?,
    canEdit: Bool,
    isOpenForThisUser: Bool,
    hasNotebook: Bool,
    slipDayAvailable: Bool
) -> DashboardRowActionGates {
    let gradingMode = props?.effectiveGradingMode.rawValue ?? GradingMode.worker.rawValue
    let submissionMode =
        props?.effectiveSubmissionMode.rawValue ?? SubmissionMode.notebook.rawValue
    let editable = submissionMode != "uploadOnly"
    return DashboardRowActionGates(
        edit: canEdit && editable && (gradingMode == "browser" || hasNotebook),
        upload: isOpenForThisUser && gradingMode != "browser",
        resetNotebook: isOpenForThisUser && hasNotebook && editable,
        slipDay: slipDayAvailable
    )
}

extension WebRoutes {

    /// Loads the viewer's grade/submission/badge maps for the dashboard.
    /// The overrides, the per-setup submission summary (latest pick + count),
    /// and the best-grade fold are independent reads and run concurrently;
    /// the summary and the fold are SQL aggregates (#1382 item 2 — this used
    /// to load every submission and every result the student ever made across
    /// the visible setups and fold them in Swift, two unbounded reads that
    /// grew all term).
    static func loadStudentDashboardGradeData(
        req: Request, user: APIUser, setups: [APITestSetup], fmt: DateFormatter
    ) async throws -> DashboardGradeData {
        var data = DashboardGradeData()
        guard let userID = user.id else { return data }
        let setupIDs = setups.compactMap(\.id)
        guard !setupIDs.isEmpty else { return data }

        // Instructor grade overrides for this student take precedence over
        // the runner-computed best grade.
        async let overridesFetch = loadGradeOverridePercents(setupIDs: setupIDs, on: req.db)
        async let summaryFetch = studentSubmissionSummaryBySetup(
            userID: userID, setupIDs: setupIDs, on: req.db)
        async let bestGradeFetch = studentBestGradePercentBySetup(
            userID: userID, setupIDs: setupIDs, on: req.db)

        let overrideMap = try await overridesFetch
        for setupID in setupIDs {
            if let pct = overrideMap[GradeOverrideKey(setupID: setupID, userID: userID)] {
                data.overridePercentBySetupID[setupID] = pct
            }
        }
        let summaryBySetup = try await summaryFetch
        data.bestGradePercentBySetupID = try await bestGradeFetch

        // The latest submission per setup, refetched as O(setups) full rows
        // for their timestamps and attempt numbers.
        let latestIDs = summaryBySetup.values.map(\.latestSubmissionID)
        let latestRows =
            latestIDs.isEmpty
            ? []
            : try await APISubmission.query(on: req.db)
                .filter(\.$id ~~ latestIDs)
                .all()
        let latestRowByID = Dictionary(
            latestRows.compactMap { row in row.id.map { ($0, row) } },
            uniquingKeysWith: { first, _ in first })
        var latestRowBySetupID: [String: APISubmission] = [:]
        for (setupID, summary) in summaryBySetup {
            data.submissionCountBySetupID[setupID] = summary.submissionCount
            guard let latest = latestRowByID[summary.latestSubmissionID] else { continue }
            latestRowBySetupID[setupID] = latest
            data.latestSubmissionBySetupID[setupID] = LatestSubmissionItem(
                submissionID: summary.latestSubmissionID,
                submittedAtText: latest.submittedAt.map { fmt.string(from: $0) } ?? "—"
            )
        }

        try await applyResultDerivedData(
            req: req, userID: userID, setups: setups,
            latestRowBySetupID: latestRowBySetupID, data: &data)
        return data
    }

    /// The result-derived phase of the grade-data load: latest-submission
    /// badges and the class badges this user holds.  Reads results only for
    /// the latest submission per setup plus its prior attempt (the Rally
    /// badge's grade-jump input) — never the full history (#1382 item 2).
    /// No-op when the student has no submissions.
    private static func applyResultDerivedData(
        req: Request, userID: UUID, setups: [APITestSetup],
        latestRowBySetupID: [String: APISubmission],
        data: inout DashboardGradeData
    ) async throws {
        guard !latestRowBySetupID.isEmpty else { return }
        let setupIDs = setups.compactMap(\.id)
        // Class-wide badges this user currently holds across all setups; runs
        // concurrently with the prior-attempt and result fetches below.
        async let classAchievementsFetch = APIClassAchievement.query(on: req.db)
            .filter(\.$userID == userID)
            .filter(\.$testSetupID ~~ setupIDs)
            .all()
        let achievementBySetup = BuiltInAchievements.achievementDataBySetup(setups: setups)
        let priorBySetupID = try await loadPriorAttemptRows(
            req: req, userID: userID, latestRowBySetupID: latestRowBySetupID)

        // Results for the latest + prior submissions only, newest-first (the
        // worker-first preference depends on that order).
        var interestingIDs = latestRowBySetupID.values.compactMap(\.id)
        interestingIDs.append(contentsOf: priorBySetupID.values.compactMap(\.id))
        let resultRows = try await APIResult.query(on: req.db)
            .filter(\.$submissionID ~~ interestingIDs)
            .sort(\.$receivedAt, .descending)
            .all()
        let preferredResultBySubmissionID = preferredResultsWorkerFirst(resultRows)

        // Badge evaluation needs the collection (executionTimeMs) for each
        // LATEST submission's preferred result only — batch-fetch just those
        // blobs from the side table (#1173), one per dashboard row at most.
        let latestResultIDs = data.latestSubmissionBySetupID.values.compactMap {
            preferredResultBySubmissionID[$0.submissionID]?.id
        }
        let latestBlobs = try await collectionJSONByResultID(for: latestResultIDs, on: req.db)
        let badgeResults = BadgeResultData(
            preferredResultBySubmissionID: preferredResultBySubmissionID,
            collectionByResultID: latestBlobs.compactMapValues(decodedCollection(from:))
        )

        for (setupID, latest) in data.latestSubmissionBySetupID {
            guard let latestRow = latestRowBySetupID[setupID] else { continue }
            if let badges = latestSubmissionBadges(
                latestRow: latestRow, latest: latest,
                priorRow: priorBySetupID[setupID],
                badgeResults: badgeResults,
                perSubmission: achievementBySetup[setupID]?.perSubmission,
                disabled: achievementBySetup[setupID]?.disabled ?? [])
            {
                data.latestBadgesBySetupID[setupID] = badges
            }
        }

        let classAchievements = try await classAchievementsFetch
        for ach in classAchievements {
            if let badge = AchievementBadge.forClassAchievement(
                ach.achievementID,
                manifestAchievements: achievementBySetup[ach.testSetupID]?.achievements ?? [],
                disabled: achievementBySetup[ach.testSetupID]?.disabled ?? [])
            {
                data.latestBadgesBySetupID[ach.testSetupID, default: []].append(badge)
            }
        }
    }

    /// The newest submission at attempt (latest − 1) per setup — the Rally
    /// badge's prior-grade input — fetched as one bounded OR-group query in
    /// place of the full-history load it used to be picked from.
    private static func loadPriorAttemptRows(
        req: Request, userID: UUID,
        latestRowBySetupID: [String: APISubmission]
    ) async throws -> [String: APISubmission] {
        let priorPairs: [(setupID: String, attempt: Int)] = latestRowBySetupID.compactMap { entry in
            let latestAttempt = entry.value.attemptNumber ?? 1
            guard latestAttempt >= 2 else { return nil }
            return (entry.key, latestAttempt - 1)
        }
        guard !priorPairs.isEmpty else { return [:] }
        let priorRows = try await APISubmission.query(on: req.db)
            .filter(\.$userID == userID)
            .filter(\.$kind == APISubmission.Kind.student)
            .group(.or) { or in
                for pair in priorPairs {
                    or.group(.and) { and in
                        and.filter(\.$testSetupID == pair.setupID)
                        and.filter(\.$attemptNumber == pair.attempt)
                    }
                }
            }
            .sort(\.$submittedAt, .descending)
            .all()
        var priorBySetupID: [String: APISubmission] = [:]
        for row in priorRows where priorBySetupID[row.testSetupID] == nil {
            priorBySetupID[row.testSetupID] = row
        }
        return priorBySetupID
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

    /// The result-derived badge inputs that don't vary per setup: the
    /// preferred result per submission, and the decoded collection per
    /// latest-submission preferred result (side table, #1173).
    private struct BadgeResultData {
        let preferredResultBySubmissionID: [String: APIResult]
        let collectionByResultID: [String: TestOutcomeCollection]
    }

    /// The per-submission badges for one setup's latest submission, or nil
    /// when it has no decodable graded result.
    private static func latestSubmissionBadges(
        latestRow: APISubmission,
        latest: LatestSubmissionItem,
        priorRow: APISubmission?,
        badgeResults: BadgeResultData,
        perSubmission: [Achievement]?,
        disabled: Set<String>
    ) -> [AchievementBadge]? {
        guard
            let result = badgeResults.preferredResultBySubmissionID[latest.submissionID],
            let resultID = result.id,
            let collection = badgeResults.collectionByResultID[resultID],
            let gradePercent = gradePercent(from: collection)
        else { return nil }
        let latestAttempt = latestRow.attemptNumber ?? 1
        let priorGradePercent: Int? = priorRow.flatMap { prior in
            guard let priorID = prior.id,
                let priorResult = badgeResults.preferredResultBySubmissionID[priorID]
            else { return nil }
            return priorResult.gradePercentValue
        }
        return AchievementBadge.forSubmission(
            BadgeContext(
                attemptNumber: latestAttempt,
                gradePercent: gradePercent,
                executionTimeMs: collection.executionTimeMs,
                priorGradePercent: priorGradePercent,
                outcomes: collection.outcomes
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
        let (status, staffOnly) = dashboardRowStatus(
            assignment: assignment, isActiveCourseStaff: context.isActiveCourseStaff)
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
        let slipDayLabel = slipDayActionLabel(
            assignment: assignment, extensionDueAt: extensionDueAt,
            setupID: setupID, context: context)
        let badgeSplit = AchievementBadge.dashboardSplit(context.gradeData.latestBadgesBySetupID[setupID] ?? [])
        let gates = dashboardRowActionGates(
            props: props, canEdit: canEdit, isOpenForThisUser: isOpenForThisUser,
            hasNotebook: hasNotebook, slipDayAvailable: slipDayLabel != nil)
        return TestSetupRow(
            id: setupID,
            title: assignment?.title,
            notebookURL: vanityBaseURL ?? "/testsetups/\(setupID)/notebook",
            submitURL: vanityBaseURL.map { "\($0)/submit" } ?? "/testsetups/\(setupID)/submit",
            historyURL: vanityBaseURL.map { "\($0)/history" } ?? "/testsetups/\(setupID)/history",
            suiteCount: props?.testSuites.count ?? 0,
            createdAt: setup.createdAt.map { context.fmt.string(from: $0) } ?? "—",
            dueAt: assignment?.dueAt.map { context.fmt.string(from: $0) },
            dueAtISO: assignment?.dueAt.map(iso8601String),
            opensAtText: notYetOpen ? assignment?.startsAt.map { context.fmt.string(from: $0) } : nil,
            status: displayStatus,
            staffOnly: staffOnly,
            isOpen: isOpenForThisUser,
            canEdit: canEdit,
            gradingMode: props?.effectiveGradingMode.rawValue ?? GradingMode.worker.rawValue,
            // EFFECTIVE, matching `gradingMode` beside it. The dashboard gates
            // its Edit and Open-editor actions on this, and a language with no
            // vendored kernel has no editor to open however the manifest is
            // spelled — the notebook route already redirects such a request, so
            // offering the link only led somewhere else. The manifest-writing
            // sites keep the STORED value: they round-trip the field, and
            // substituting the effective one there would silently rewrite it.
            submissionMode: props?.effectiveSubmissionMode.rawValue
                ?? SubmissionMode.notebook.rawValue,
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
            effectiveDueAtText: effectiveDueAt.map { context.fmt.string(from: $0) },
            effectiveDueAtISO: effectiveDueAt.map(iso8601String),
            showEditAction: gates.edit,
            showUploadAction: gates.upload,
            showResetNotebookAction: gates.resetNotebook,
            hasAnyAction: gates.any,
            slipDayAvailable: gates.slipDay,
            slipDayURL: "/testsetups/\(setupID)/slip-day",
            slipDayActionLabel: slipDayLabel ?? ""
        )
    }

    /// The slip-day action's tooltip/aria text for one row (#1228), nil when
    /// the action is hidden.  Offered only to students, after the deadline,
    /// inside the claim window, with balance, and never on top of a
    /// staff-granted extension (an extension row the slip-day ledger did not
    /// produce) or a staff-only preview.
    private static func slipDayActionLabel(
        assignment: APIAssignment?,
        extensionDueAt: Date?,
        setupID: String,
        context: IndexRowContext
    ) -> String? {
        guard let assignment, assignment.visibility != .preview,
            !context.isActiveCourseStaff
        else { return nil }
        let spentCount = context.slipDay.spendCountBySetupID[setupID] ?? 0
        let offer = slipDayOffer(
            policy: context.slipDay.policy,
            dueAt: assignment.dueAt,
            balance: context.slipDay.balance,
            spentOnAssignment: spentCount,
            hasForeignExtension: extensionDueAt != nil && spentCount == 0)
        guard let offer else { return nil }
        let deadlineText = context.fmt.string(from: offer.newDeadline)
        return offer.isStacked
            ? "Use another slip day — extends your deadline to \(deadlineText)"
            : "Use a slip day — extends your deadline to \(deadlineText)"
    }
}
