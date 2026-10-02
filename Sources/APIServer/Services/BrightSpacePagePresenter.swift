// APIServer/Services/BrightSpacePagePresenter.swift
//
// Assembles the instructor LEARN tab's view model
// (`InstructorBrightspaceContext`) from the models and the sync log: the
// per-instructor connection, the identity the course pushes as, the
// assignment → grade-item rows with their per-student rollups, and the
// roster-readiness panel.
//
// Functions over a database and the application, never a `Request`. The
// route handler (`InstructorLMSRoutes+BrightSpace.swift`) resolves the
// active course and the one-shot flashes, then calls `context`. Moved out of
// the route extension in #1654, where the read side shared one file with the
// connection actions and the org-unit binding.

import Core
import Fluent
import Foundation
import Vapor

enum BrightSpacePagePresenter {

    /// The one-shot flashes the connect / disconnect / designate actions
    /// leave in the session for the next page load.
    struct Flashes {
        let success: String?
        let error: String?

        static let none = Flashes(success: nil, error: nil)
    }

    /// How the active course's grade-sync identity is shown: the display
    /// name (designated instructor, the disconnected instructor's username,
    /// or the deployment-wide fallback), whether that identity still has a
    /// stored key, and whether it is the requesting user.
    struct SyncIdentity {
        let name: String?
        let connected: Bool
        let isMe: Bool
    }

    /// What the LEARN page's title bar and facts card say, gathered in one place.
    struct LearnPageFacts {
        let usesServiceAccount: Bool
        let syncHealthy: Bool
        let pushesAsText: String
        let pushesAsNote: String
        let lastSyncISO: String?
        let lastSyncText: String
        let canBindOrgUnit: Bool
        let readinessSummary: String
    }

    /// Everything `learnPageFacts` reads, so the call site stays one value.
    struct LearnFactsInput {
        let usesServiceAccount: Bool
        let syncEnabled: Bool
        let syncIdentity: InstructorBrightspaceContext.SyncIdentityPanel
        let identity: SyncIdentity
        let accountConnected: Bool
        let isArchived: Bool
        let newestAttempt: Date?
        let unreachableCount: Int
        let lastCheckedText: String
    }

    // MARK: - Page context

    /// Assembles the full BrightSpace-tab context for the active course.
    static func context(
        user: APIUser,
        courseState: ResolvedCourseState,
        flashes: Flashes,
        on db: Database,
        application: Application
    ) async throws -> InstructorBrightspaceContext {
        let userContext = CurrentUserContext(
            user: user, activeCourse: courseState.active, enrolledCourses: courseState.all)
        // "Enabled" = configured at the app level (URL/App ID/App Key); a user
        // key may still be awaited via per-instructor connect.
        let syncEnabled = application.brightSpaceAppCredentials != nil
        let fmt = waterlooDateTimeFormatter()

        // This instructor's own LEARN connection (course-independent).
        let myCredential: APIBrightSpaceCredential?
        if let uid = user.id {
            myCredential = try await BrightSpaceCredentialStore.load(userID: uid, on: db)
        } else {
            myCredential = nil
        }
        let account = InstructorBrightspaceContext.AccountPanel(
            connected: myCredential != nil,
            identity: myCredential?.identityName,
            since: myCredential?.capturedAt.map { " (since \(fmt.string(from: $0)))" })

        guard let courseUUID = courseState.activeCourseUUID,
            let course = try await APICourse.find(courseUUID, on: db)
        else {
            return noCourseContext(
                userContext: userContext, hasActiveCourse: courseState.active != nil,
                syncEnabled: syncEnabled, account: account, flashes: flashes)
        }

        let orgUnitID = course.brightspaceOrgUnitID
        let courseLinked = !(orgUnitID ?? "").isEmpty

        // How the course's grade-sync identity is shown + whether it's still connected.
        let identity = try await syncIdentity(course: course, user: user, on: db, application: application)
        let syncIdentity = InstructorBrightspaceContext.SyncIdentityPanel(
            name: identity.name,
            hasName: identity.name != nil,
            isMe: identity.isMe,
            connected: identity.connected,
            needsReconnect: identity.name != nil && !identity.connected)

        let (assignmentRows, newestAttempt) = try await assignmentData(courseUUID: courseUUID, on: db, fmt: fmt)
        let (readiness, unreachableStudents) = try await readiness(courseUUID: courseUUID, on: db, fmt: fmt)

        let orgUnitDisplay: String? =
            courseLinked
            ? {
                if let name = course.brightspaceOrgUnitName, !name.isEmpty {
                    return "\(name) (\(orgUnitID ?? ""))"
                }
                return orgUnitID
            }()
            : nil
        let showIdentityActions = account.connected && !course.isArchived
        let facts = learnPageFacts(
            LearnFactsInput(
                usesServiceAccount: application.brightSpaceUsesServiceAccount,
                syncEnabled: syncEnabled, syncIdentity: syncIdentity, identity: identity,
                accountConnected: account.connected, isArchived: course.isArchived,
                newestAttempt: newestAttempt, unreachableCount: unreachableStudents.count,
                lastCheckedText: readiness.lastCheckedText),
            fmt: fmt)

        return InstructorBrightspaceContext(
            currentUser: userContext, activeInstructorTab: "brightspace",
            hasActiveCourse: true, courseIsArchived: course.isArchived,
            brightspaceSyncEnabled: syncEnabled, courseLinked: courseLinked,
            orgUnitDisplay: orgUnitDisplay, orgUnitFieldValue: orgUnitID ?? "",
            account: account,
            syncIdentity: syncIdentity,
            showConnectForm: syncEnabled && !account.connected && !course.isArchived,
            showIdentityActions: showIdentityActions,
            showUseMyIdentity: showIdentityActions && !syncIdentity.isMe,
            flashSuccess: flashes.success, flashError: flashes.error,
            canSyncNow: syncEnabled && !course.isArchived && !course.usesLTIGrades,
            doNotSyncToken: BrightspaceSync.doNotSyncToken,
            assignmentRows: assignmentRows, hasAssignments: !assignmentRows.isEmpty,
            canReconcile: courseLinked && !course.isArchived,
            unreachableStudents: unreachableStudents, hasUnreachable: !unreachableStudents.isEmpty,
            showLTIGradesLink: course.ltiPlatformID != nil,
            usesLTIGrades: course.usesLTIGrades,
            usesServiceAccount: facts.usesServiceAccount,
            syncHealthy: facts.syncHealthy,
            pushesAsText: facts.pushesAsText,
            pushesAsNote: facts.pushesAsNote,
            lastSyncISO: facts.lastSyncISO,
            lastSyncText: facts.lastSyncText,
            canBindOrgUnit: facts.canBindOrgUnit,
            readinessSummary: facts.readinessSummary)
    }

    /// The context for the "no active course selected" state: the
    /// per-instructor account and the flashes still render, but everything
    /// course-scoped is empty.
    private static func noCourseContext(
        userContext: CurrentUserContext,
        hasActiveCourse: Bool,
        syncEnabled: Bool,
        account: InstructorBrightspaceContext.AccountPanel,
        flashes: Flashes
    ) -> InstructorBrightspaceContext {
        InstructorBrightspaceContext(
            currentUser: userContext, activeInstructorTab: "brightspace",
            hasActiveCourse: hasActiveCourse, courseIsArchived: false,
            brightspaceSyncEnabled: syncEnabled, courseLinked: false,
            orgUnitDisplay: nil, orgUnitFieldValue: "",
            account: account,
            syncIdentity: .empty,
            showConnectForm: syncEnabled && !account.connected,
            showIdentityActions: false, showUseMyIdentity: false,
            flashSuccess: flashes.success, flashError: flashes.error,
            canSyncNow: false, doNotSyncToken: BrightspaceSync.doNotSyncToken,
            assignmentRows: [], hasAssignments: false,
            canReconcile: false,
            unreachableStudents: [], hasUnreachable: false)
    }

    /// Resolves how the active course's grade-sync identity is shown.
    static func syncIdentity(
        course: APICourse, user: APIUser, on db: Database, application: Application
    ) async throws -> SyncIdentity {
        let isMe = course.brightspaceSyncUserID != nil && course.brightspaceSyncUserID == user.id
        if let syncUserID = course.brightspaceSyncUserID {
            if let cred = try await BrightSpaceCredentialStore.load(userID: syncUserID, on: db) {
                return SyncIdentity(name: cred.identityName, connected: true, isMe: isMe)
            }
            // Designated but disconnected — fall back to the username so the UI
            // can flag that the identity needs to reconnect.
            let username = try await APIUser.find(syncUserID, on: db)?.username
            return SyncIdentity(name: username, connected: false, isMe: isMe)
        }
        if application.brightSpaceClient != nil {
            return SyncIdentity(name: "Deployment default account", connected: true, isMe: isMe)
        }
        return SyncIdentity(name: nil, connected: false, isMe: isMe)
    }

    // MARK: - Facts card

    static func learnPageFacts(_ input: LearnFactsInput, fmt: DateFormatter) -> LearnPageFacts {
        let pushesAs = pushesAs(identity: input.identity, usesServiceAccount: input.usesServiceAccount)
        let noun = input.unreachableCount == 1 ? "student" : "students"
        return LearnPageFacts(
            usesServiceAccount: input.usesServiceAccount,
            syncHealthy: input.syncEnabled && !input.syncIdentity.needsReconnect
                && input.identity.connected,
            pushesAsText: pushesAs.text,
            pushesAsNote: pushesAs.note,
            lastSyncISO: input.newestAttempt.map { ISO8601DateFormatter().string(from: $0) },
            lastSyncText: input.newestAttempt.map { fmt.string(from: $0) } ?? "Never",
            canBindOrgUnit: !input.isArchived && (input.usesServiceAccount || input.accountConnected),
            readinessSummary:
                "\(input.unreachableCount) \(noun) can't receive grades · checked \(input.lastCheckedText)")
    }

    /// Who the facts card says the course pushes as. A course that still names a
    /// designated instructor pushes as them, so the page says so rather than
    /// claiming the service account.
    static func pushesAs(identity: SyncIdentity, usesServiceAccount: Bool) -> (text: String, note: String) {
        if let name = identity.name, name != "Deployment default account" {
            return (name, identity.connected ? "" : "Disconnected: grade pushes are paused")
        }
        if usesServiceAccount { return ("Service account", "Managed by Chickadee admins") }
        return ("Not connected", "Connect a LEARN account to sync grades")
    }

    // MARK: - Grade-item rows

    /// The grade-item rows, and the time of the newest sync attempt for the
    /// course, in one pass over the assignments and recent sync log.
    static func assignmentData(
        courseUUID: UUID, on db: Database, fmt: DateFormatter
    ) async throws -> (rows: [BrightspaceAssignmentRow], newestAttempt: Date?) {
        // Assignments, sorted to match the dashboard ordering.
        let assignments = try await APIAssignment.query(on: db)
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
        let logModels = try await APIBrightSpaceSyncLog.query(on: db)
            .filter(\.$courseID == courseUUID)
            .sort(\.$attemptedAt, .descending)
            .range(..<50)
            .all()

        // Latest log per test setup → per-assignment status badge.
        var latestBySetup: [String: APIBrightSpaceSyncLog] = [:]
        for log in logModels where latestBySetup[log.testSetupID] == nil {
            latestBySetup[log.testSetupID] = log
        }

        // The rollups still power the per-assignment counts and the roster
        // panel; the page-level summary/readiness cards were removed from the
        // template in c747962, so those aggregates are discarded (#1114).
        let (_, perSetupCounts) = try await syncSummary(courseUUID: courseUUID, setupIDs: setupIDs, on: db)
        let rows = assignmentRows(
            assignments: assignments, latestBySetup: latestBySetup,
            perSetupCounts: perSetupCounts, fmt: fmt)

        return (rows, logModels.compactMap(\.attemptedAt).max())
    }

    /// Builds the per-assignment mapping rows: grade-item ID, latest-sync badge,
    /// and the per-assignment synced/pending/errored rollup (from `perSetupCounts`).
    private static func assignmentRows(
        assignments: [APIAssignment],
        latestBySetup: [String: APIBrightSpaceSyncLog],
        perSetupCounts: [String: SetupSyncCounts],
        fmt: DateFormatter
    ) -> [BrightspaceAssignmentRow] {
        assignments.map { a in
            let last = latestBySetup[a.testSetupID]
            let counts = perSetupCounts[a.testSetupID] ?? SetupSyncCounts()
            let gradeFieldValue =
                a.brightspaceSyncExcluded == true
                ? BrightspaceSync.doNotSyncToken
                : (a.brightspaceGradeObjectID ?? "")
            return BrightspaceAssignmentRow(
                assignmentID: a.publicID,
                title: a.title,
                gradeFieldValue: gradeFieldValue,
                lastSyncText: last?.attemptedAt.map { fmt.string(from: $0) } ?? "—",
                lastSyncStatus: last?.status ?? "none",
                lastSyncDetail: last?.detail,
                syncedCount: counts.synced,
                pendingCount: counts.pending,
                erroredCount: counts.errored,
                hasSyncActivity: counts.synced + counts.pending + counts.errored > 0,
                hasPending: counts.pending > 0,
                hasErrored: counts.errored > 0,
                isMapped: !gradeFieldValue.isEmpty && gradeFieldValue != BrightspaceSync.doNotSyncToken,
                syncDetailText: syncDetailText(
                    status: last?.status ?? "none", detail: last?.detail,
                    at: last?.attemptedAt.map { fmt.string(from: $0) }),
                hasSyncError: last?.status == "error")
        }
    }

    /// The grade-item row's details line.
    static func syncDetailText(status: String, detail: String?, at time: String?) -> String {
        switch status {
        case "error":
            let text = (detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "The last push failed" : text
        case "success": return "Last synced \(time ?? "—")"
        case "skipped": return "Last skipped \(time ?? "—")"
        default: return "Not synced yet"
        }
    }

    // MARK: - Per-assignment rollup

    /// Per-test-setup grade-sync rollup, counting **distinct students** (not
    /// rows), each bucketed once by the state of their most recent grade-sync
    /// attempt.  The buckets are mutually exclusive so a student shows up in
    /// exactly one — the instructor reads "Synced" as "students currently
    /// delivered to LEARN" and "Failed" as "students who need a fix", not a
    /// running tally of every historical push.
    struct SetupSyncCounts {
        var synced = 0
        var pending = 0
        var errored = 0

        /// Buckets one student by their latest attempt's state. A recorded error
        /// means the most recent push failed (needs attention); else a synced
        /// timestamp means it's delivered; else it's still queued.
        mutating func add(error: String?, syncedAt: Date?, pending isPending: Bool) {
            if (error ?? "").isEmpty == false {
                errored += 1
            } else if syncedAt != nil {
                synced += 1
            } else if isPending {
                pending += 1
            }
        }
    }

    /// One student's most-recent grade-sync attempt for a test setup, used to
    /// dedupe the per-assignment counts down to distinct students.
    private struct LatestSyncState {
        var attemptedAt: Date
        var error: String?
        var syncedAt: Date?
        var pending: Bool
    }

    /// Computes the per-assignment Synced/Failed rollup and the headline summary,
    /// counting **distinct students by their most recent attempt** rather than
    /// summing every historical result row.  For a student with submissions, the
    /// latest result row (by `receivedAt`) reflects the outcome of their last
    /// grade push; a no-submission student's grade rides on the override row, so
    /// that row's state is used when no result covers them.
    static func syncSummary(
        courseUUID: UUID,
        setupIDs: [String],
        on db: Database
    ) async throws -> (BrightspaceSyncSummary, [String: SetupSyncCounts]) {
        // (setupID, userID) → that student's most-recent sync state.
        struct StudentKey: Hashable {
            let setupID: String
            let userID: UUID
        }
        var latestByStudent: [StudentKey: LatestSyncState] = [:]

        // Map each student submission to its (setup, student) so a result row
        // resolves to the student whose grade it carries.
        let submissions =
            setupIDs.isEmpty
            ? []
            : try await APISubmission.query(on: db)
                .filter(\.$testSetupID ~~ setupIDs)
                .filter(\.$kind == APISubmission.Kind.student)
                .all()
        var keyBySubmissionID: [String: StudentKey] = [:]
        for submission in submissions {
            if let id = submission.id, let userID = submission.userID {
                keyBySubmissionID[id] = StudentKey(setupID: submission.testSetupID, userID: userID)
            }
        }

        // Keep each student's latest result row (highest `receivedAt`).
        let submissionIDs = Array(keyBySubmissionID.keys)
        let results =
            submissionIDs.isEmpty
            ? []
            : try await APIResult.query(on: db)
                .filter(\.$submissionID ~~ submissionIDs)
                .all()
        for result in results {
            guard let key = keyBySubmissionID[result.submissionID] else { continue }
            let received = result.receivedAt ?? Date.distantPast
            if let existing = latestByStudent[key], existing.attemptedAt >= received { continue }
            latestByStudent[key] = LatestSyncState(
                attemptedAt: received,
                error: result.brightspaceSyncError,
                syncedAt: result.brightspaceSyncedAt,
                pending: result.brightspaceSyncPending == true)
        }

        // Override-only students (no submissions) — their grade rides on the
        // override row. Skip any already covered by a result row: the latest
        // result reflects the pushed grade (override included).
        let overrides =
            setupIDs.isEmpty
            ? []
            : try await APIGradeOverride.query(on: db)
                .filter(\.$testSetupID ~~ setupIDs)
                .all()
        for override in overrides {
            let key = StudentKey(setupID: override.testSetupID, userID: override.userID)
            if latestByStudent[key] != nil { continue }
            latestByStudent[key] = LatestSyncState(
                attemptedAt: override.brightspacePendingSince ?? Date.distantPast,
                error: override.brightspaceSyncError,
                syncedAt: override.brightspaceSyncedAt,
                pending: override.brightspaceSyncPending == true)
        }

        var perSetup: [String: SetupSyncCounts] = [:]
        for (key, state) in latestByStudent {
            perSetup[key.setupID, default: SetupSyncCounts()].add(
                error: state.error, syncedAt: state.syncedAt, pending: state.pending)
        }

        var synced = 0
        var pending = 0
        var errored = 0
        for counts in perSetup.values {
            synced += counts.synced
            pending += counts.pending
            errored += counts.errored
        }

        let summary = BrightspaceSyncSummary(synced: synced, pending: pending, errored: errored)
        return (summary, perSetup)
    }

    // MARK: - Roster readiness

    /// Builds the LEARN roster-readiness panel for the active course from the
    /// persisted per-enrollment status (maintained by the readiness sweep):
    /// confirmed / unconfirmed / unreachable counts, the last-checked time, and
    /// the list of unreachable students with the reason.
    static func readiness(
        courseUUID: UUID, on db: Database, fmt: DateFormatter
    ) async throws -> (BrightspaceReadinessSummary, [BrightspaceReadinessRow]) {
        let enrollments = try await APICourseEnrollment.query(on: db)
            .filter(\.$course.$id == courseUUID)
            .all()
            .filter { $0.role == .student }
        guard !enrollments.isEmpty else {
            return (
                BrightspaceReadinessSummary(
                    confirmed: 0, unconfirmed: 0, unreachable: 0,
                    lastCheckedText: "Never", hasBeenChecked: false), []
            )
        }

        let userIDs = enrollments.map(\.userID)
        // `enrollments` is already `.student`-role only (#417 Slice G2), so the
        // global-role filter is redundant.
        let users = try await APIUser.query(on: db)
            .filter(\.$id ~~ userIDs)
            .all()
        var userByID: [UUID: APIUser] = [:]
        for user in users {
            if let id = user.id { userByID[id] = user }
        }

        var confirmed = 0
        var unconfirmed = 0
        var unreachable: [BrightspaceReadinessRow] = []
        var lastChecked: Date?
        for enrollment in enrollments {
            guard let student = userByID[enrollment.userID] else { continue }
            if let checked = enrollment.brightspaceCheckedAt {
                lastChecked = max(lastChecked ?? checked, checked)
            }
            switch enrollment.learnSyncReadiness {
            case .confirmed: confirmed += 1
            case .unconfirmed: unconfirmed += 1
            case .unreachable:
                let uid = enrollment.userID.uuidString
                let spec = try await AvatarStore.ensureSpec(for: student, on: db)
                unreachable.append(
                    BrightspaceReadinessRow(
                        username: student.username,
                        displayName: student.displayName ?? student.username,
                        detail: enrollment.brightspaceSyncDetail ?? "Not on the LEARN classlist.",
                        userID: uid,
                        unenrollURL: "/courses/\(courseUUID.uuidString)/unenroll/\(uid)",
                        // `enrollments` is student-role only, so no row is staff.
                        avatar: AvatarPresentation(
                            for: spec, size: .roster, accessibility: .decorative, isStaff: false),
                        hasAvatar: true))
            }
        }
        unreachable.sort { $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending }

        let summary = BrightspaceReadinessSummary(
            confirmed: confirmed, unconfirmed: unconfirmed, unreachable: unreachable.count,
            lastCheckedText: lastChecked.map { fmt.string(from: $0) } ?? "Never",
            hasBeenChecked: lastChecked != nil)
        return (summary, unreachable)
    }
}
