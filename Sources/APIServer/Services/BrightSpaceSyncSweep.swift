// APIServer/Services/BrightSpaceSyncSweep.swift
//
// The debounced BrightSpace grade-sync sweep: orchestration, the per-group
// grade push, sweep-wide batch loading, the per-sweep classlist / grade-object
// caches, and the 60-second monitor registration.
//
// `GradeSyncSweep` holds the dependencies that are invariant across one sweep
// (database, logger, application, the two caches); `resolveClient` stays a
// method parameter because every caller passes a non-escaping closure.  The
// free function `sweepBrightSpaceGradeSync` is the stable entry point the
// monitor, the manual "Sync now" routes, and the tests call.
//
// Grade selection lives in BrightSpaceGradeSelection.swift; queued grade
// removals in BrightSpaceGradeClears.swift; the sync-row flag bookkeeping and
// retry classification in BrightSpaceGradeSyncService.swift.

import Fluent
import Foundation
import Vapor

// MARK: - Sweep entry point

/// Sweeps for pending grade pushes and executes them.
/// Returns the number of results processed (success or failure).
///
/// All cross-table lookups (submissions, assignments, courses, users) are
/// batch-loaded once per sweep instead of row-by-row, and pending results
/// that resolve to the same (student, test setup) pair are pushed once as a
/// group — the push computes the student's best grade across the whole test
/// setup anyway, so every row in the group is marked exactly the way the
/// pushed one is.
@discardableResult
func sweepBrightSpaceGradeSync(
    on db: Database,
    debounceSecs: TimeInterval,
    resolveClient: (APICourse) async throws -> (any BrightSpaceGrading)?,
    logger: Logger,
    application: Application,
    now: Date = Date(),
    bypassDebounce: Bool = false
) async throws -> Int {
    let sweep = GradeSyncSweep(db: db, logger: logger, application: application)
    return try await sweep.sweep(
        debounceSecs: debounceSecs, resolveClient: resolveClient, now: now,
        bypassDebounce: bypassDebounce)
}

// MARK: - Sweep orchestration

/// One grade-sync sweep's invariant dependencies plus its per-sweep caches.
/// Construct one per sweep (the free function `sweepBrightSpaceGradeSync` does
/// this) so the caches never outlive the sweep that populated them.
struct GradeSyncSweep {
    let db: any Database
    let logger: Logger
    let application: Application
    /// One classlist read per course, shared across all of this sweep's pushes.
    let classlistCache = ClasslistUserIDCache()
    /// One grade-object fetch per item, shared across all of this sweep's pushes.
    let gradeObjectCache = GradeObjectInfoCache()

    /// Runs one sweep. See `sweepBrightSpaceGradeSync` for the contract.
    @discardableResult
    func sweep(
        debounceSecs: TimeInterval,
        resolveClient: (APICourse) async throws -> (any BrightSpaceGrading)?,
        now: Date = Date(),
        bypassDebounce: Bool = false
    ) async throws -> Int {
        // `bypassDebounce` is the manual "Sync now" path: push every pending row
        // immediately instead of waiting out the debounce window (#1117 — callers
        // used to fabricate a future `now` to the same effect).
        let cutoff = bypassDebounce ? Date.distantFuture : now.addingTimeInterval(-debounceSecs)

        // All results that are past the debounce window. May be empty — an
        // override on a student with no submissions has no result row, so the sweep
        // must still run the override scan below even when nothing here is pending.
        // (With an empty `pending`, loadGradeSyncBatchContext issues no queries and
        // the result loops don't execute, so there's no early-return short-circuit.)
        let pending = try await APIResult.query(on: db)
            .filter(\.$brightspaceSyncPending == true)
            .filter(\.$brightspacePendingSince <= cutoff)
            .all()

        let context = try await loadGradeSyncBatchContext(for: pending)

        var processed = 0

        // Group pushable results by (student, test setup).  Results whose
        // submission is missing or isn't a student submission are no-ops handled
        // row-by-row, exactly as before.
        var groups: [GradePushKey: [APIResult]] = [:]
        var groupOrder: [GradePushKey] = []

        for result in pending {
            guard let submission = context.submissionsByID[result.submissionID],
                submission.kind == APISubmission.Kind.student,
                let userID = submission.userID
            else {
                // Orphaned result or validation submission — just clear the flag.
                do {
                    result.brightspaceSyncPending = false
                    try await result.save(on: db)
                    processed += 1
                } catch {
                    await recordSweepFailure([result], error: error, db: db, logger: logger)
                }
                continue
            }
            let key = GradePushKey(userID: userID, testSetupID: submission.testSetupID)
            if groups[key] == nil { groupOrder.append(key) }
            groups[key, default: []].append(result)
        }

        var targets: [GradePushTarget] = groupOrder.compactMap { key in
            guard let results = groups[key] else { return nil }
            let assignment = context.assignmentsBySetupID[key.testSetupID]
            return GradePushTarget(
                userID: key.userID,
                testSetupID: key.testSetupID,
                results: results,
                pendingOverride: nil,
                assignment: assignment,
                course: assignment.flatMap { context.coursesByID[$0.courseID] },
                user: context.usersByID[key.userID]
            )
        }

        // Override-only targets: instructor overrides on students with no
        // submissions, whose pending flag the override row carries directly (there
        // is no result row).  De-duped against the result-driven groups so a
        // student who also has submissions is pushed once via their results.
        let coveredKeys = Set(groupOrder)
        targets += try await pendingOverrideTargets(coveredKeys: coveredKeys, cutoff: cutoff)

        for target in targets {
            let syncRows = target.syncRows
            do {
                // Explicitly excluded from LEARN sync (instructor chose "Do not
                // sync") — a deliberate no-op, distinct from "no grade item
                // configured": clear the pending flag and record nothing, so the row
                // reads as neither synced nor errored.
                if target.assignment?.brightspaceSyncExcluded == true {
                    try await clearPendingFlag(syncRows, on: db)
                    processed += syncRows.count
                    continue
                }
                let pushed = try await pushGrade(for: target, resolveClient: resolveClient)
                if pushed { processed += syncRows.count }
            } catch {
                await recordSweepFailure(syncRows, error: error, db: db, logger: logger)
            }
        }

        // Pending grade REMOVALS (override cleared on a previously-synced
        // no-submission student). A push queued for the same (student, setup) this
        // sweep supersedes the clear, so pass the keys we're about to push.
        let pushedKeys = Set(targets.map { GradePushKey(userID: $0.userID, testSetupID: $0.testSetupID) })
        processed += try await processPendingGradeClears(
            pushedKeys: pushedKeys, cutoff: cutoff, resolveClient: resolveClient)
        return processed
    }

    /// Builds override-only push targets from `grade_overrides` rows flagged
    /// pending past the debounce cutoff.  A row whose (student, test setup) is
    /// already covered by a result-driven group has its pending flag cleared in
    /// place (the results path will push it) and yields no target.
    private func pendingOverrideTargets(
        coveredKeys: Set<GradePushKey>,
        cutoff: Date
    ) async throws -> [GradePushTarget] {
        let pendingOverrides = try await APIGradeOverride.query(on: db)
            .filter(\.$brightspaceSyncPending == true)
            .filter(\.$brightspacePendingSince <= cutoff)
            .all()
        guard !pendingOverrides.isEmpty else { return [] }

        var overrideOnly: [APIGradeOverride] = []
        for override in pendingOverrides {
            let key = GradePushKey(userID: override.userID, testSetupID: override.testSetupID)
            if coveredKeys.contains(key) {
                // The result-driven group will push this (student, setup); the
                // override row's own flag is redundant — clear it.
                override.brightspaceSyncPending = false
                try await override.save(on: db)
            } else {
                overrideOnly.append(override)
            }
        }
        guard !overrideOnly.isEmpty else { return [] }

        let context = try await loadSyncContextForKeys(
            setupIDs: overrideOnly.map(\.testSetupID), userIDs: overrideOnly.map(\.userID))
        return overrideOnly.map { override in
            let assignment = context.assignmentsBySetupID[override.testSetupID]
            return GradePushTarget(
                userID: override.userID,
                testSetupID: override.testSetupID,
                results: [],
                pendingOverride: override,
                assignment: assignment,
                course: assignment.flatMap { context.coursesByID[$0.courseID] },
                user: context.usersByID[override.userID]
            )
        }
    }
}

// MARK: - Per-group push

extension GradeSyncSweep {
    /// Pushes one group's grade. Returns false when the push is *deferred* (the
    /// course has no grade-sync identity connected yet) so the caller leaves the
    /// rows pending for a later sweep; true on every terminal outcome (pushed,
    /// skipped, or a no-op flag clear).
    @discardableResult
    private func pushGrade(
        for target: GradePushTarget,
        resolveClient: (APICourse) async throws -> (any BrightSpaceGrading)?
    ) async throws -> Bool {
        let userID = target.userID
        let testSetupID = target.testSetupID
        let syncRows = target.syncRows

        // The assignment for this test setup must have a grade item configured.
        guard let assignment = target.assignment,
            let gradeObjectID = assignment.brightspaceGradeObjectID,
            !gradeObjectID.isEmpty
        else {
            // No BrightSpace grade item configured — no-op.
            try await clearPendingFlag(syncRows, on: db)
            return true
        }

        // The course must have an org unit ID.
        guard let course = target.course,
            let orgUnitID = course.brightspaceOrgUnitID,
            !orgUnitID.isEmpty
        else {
            try await clearPendingFlag(syncRows, on: db)
            return true
        }

        // Resolve the identity this course pushes as (designated instructor, else
        // the deployment-wide fallback). When none is connected yet, defer: leave
        // the rows pending so the grade pushes once an instructor connects, rather
        // than clearing the flag as a permanent no-op.
        guard let client = try await resolveClient(course) else {
            return false
        }

        // Best grade for this student across the test setup. nil → no submissions
        // yet (nothing to push); throws if submissions exist but yield no points.
        guard
            let grade = try await bestGradeForStudent(userID: userID, testSetupID: testSetupID, db: db)
        else {
            try await clearPendingFlag(syncRows, on: db)
            return true
        }

        // Username snapshot for the sync log (readable without a join).
        let username = target.user?.username ?? userID.uuidString

        // Appends one row to the sync log. Best-effort: a logging failure must
        // never abort or retry a grade push, so errors are swallowed. Captures
        // the surrounding push context so callers pass only status + points + detail.
        func appendSyncLog(
            _ status: APIBrightSpaceSyncLog.Status, points: Double, detail: String?
        )
            async
        {
            let entry = APIBrightSpaceSyncLog(
                courseID: course.id,
                testSetupID: assignment.testSetupID,
                assignmentTitle: assignment.title,
                userID: userID,
                username: username,
                orgUnitID: orgUnitID,
                gradeObjectID: gradeObjectID,
                points: points,
                status: status,
                detail: detail
            )
            try? await entry.save(on: db)
        }

        // Flags every sync row terminally (cleared + error recorded) and logs a
        // skip — the shared shape for "we won't push this, and here's why".
        func recordTerminalSkip(_ message: String, points: Double) async throws {
            for row in syncRows {
                row.brightspaceSyncPending = false
                row.brightspaceSyncError = message
                try await row.save(on: db)
            }
            await appendSyncLog(.skipped, points: points, detail: message)
        }

        // Fetch the grade item, refuse non-numeric items, and scale onto its max.
        let scaled = await scaledGradePush(
            grade: grade, orgUnitID: orgUnitID, gradeObjectID: gradeObjectID,
            client: client, gradeObjectCache: gradeObjectCache, application: application)
        if let refusal = scaled.refusal {
            try await recordTerminalSkip(refusal, points: grade.points)
            return true
        }
        let pushPoints = scaled.pushPoints
        let gradeObject = scaled.gradeObject

        let bsUserID = try await resolveBSUserID(for: target.user, orgUnitID: orgUnitID, client: client)
        guard let bsUserID else {
            try await recordTerminalSkip(
                "Student is not on the LEARN classlist for org unit \(orgUnitID)", points: pushPoints)
            return true
        }

        // Push the grade.
        do {
            try await client.pushGrade(
                orgUnitID: orgUnitID,
                gradeObjectID: gradeObjectID,
                bsUserID: bsUserID,
                earnedPoints: pushPoints,
                on: application
            )
        } catch {
            await invalidateCachedUserIDOnNotFound(
                error, user: target.user, describing: "'\(assignment.title)'")
            // Enrich with item context here (the sweep's catch lacks it), then
            // rethrow so the existing per-group error handling still runs.
            let maxDesc = gradeObject?.maxPoints.map { "\($0)" } ?? "unset"
            let detail = brightspacePushRejectionDetail(
                itemName: gradeObject?.name ?? gradeObjectID, maxPoints: maxDesc, error: error)
            await appendSyncLog(.error, points: pushPoints, detail: detail)
            throw error
        }

        let syncedAt = Date()
        for row in syncRows {
            row.brightspaceSyncPending = false
            row.brightspacePendingSince = nil
            row.brightspaceSyncedAt = syncedAt
            row.brightspaceSyncError = nil
            try await row.save(on: db)
        }

        await appendSyncLog(.success, points: pushPoints, detail: nil)

        application.logger.info(
            "BrightSpace grade synced: user \(userID) assignment '\(assignment.title)' → \(pushPoints) pts")
        return true
    }

    /// Drops a student's cached D2L user id after a 404 grade push.
    ///
    /// A 404 from the values endpoint is about the *user*, not the item: the
    /// grade object is fetched successfully immediately before the push, so the
    /// org unit and the item both exist. The usual cause is a cached
    /// `brightspaceUserID` for a student who isn't (or is no longer) in this org
    /// unit — most often one resolved through the LMS-global OrgDefinedId
    /// lookup. Clearing it makes the next attempt re-resolve against the
    /// classlist; without this the same unusable id is replayed on every future
    /// push, for every assignment, and the failure never heals.
    ///
    /// Deliberately narrow: any other status says nothing about the identity,
    /// so the cached id survives it.
    private func invalidateCachedUserIDOnNotFound(
        _ error: Error, user: APIUser?, describing context: String
    ) async {
        guard let syncError = error as? BrightSpaceSyncError,
            case .gradePushFailed(let status, _) = syncError,
            status == 404,
            let user,
            user.brightspaceUserID != nil
        else { return }
        user.brightspaceUserID = nil
        try? await user.save(on: db)
        // User id in metadata only — message text reaches the admin query_logs
        // buffer unredacted (compliance audit F-1).
        application.logger.warning(
            "BrightSpace grade push 404 for \(context) — cleared the cached D2L user id so the next attempt re-resolves",
            metadata: ["user_id": .string(user.id?.uuidString ?? "<nil>")]
        )
    }

    /// Resolves the student's D2L user ID via the course classlist (cached per
    /// sweep). A classlist read failure yields a nil index, which
    /// `resolvedBrightSpaceUserID` treats as "authority unavailable" — distinct
    /// from a successful read in which the student simply doesn't appear.
    func resolveBSUserID(
        for user: APIUser?,
        orgUnitID: String,
        client: any BrightSpaceGrading
    ) async throws -> String? {
        var identityIndex: BrightSpaceIdentityIndex?
        do {
            identityIndex = try await classlistCache.identityIndex(
                orgUnitID: orgUnitID, client: client, application: application)
        } catch {
            application.logger.warning(
                "BrightSpace classlist resolve failed for org unit \(orgUnitID): \(error)")
            identityIndex = nil
        }
        return try await resolvedBrightSpaceUserID(
            for: user, identityIndex: identityIndex, db: db, client: client, application: application)
    }
}

/// Returns the cached D2L user ID for `user`, resolving it on first sync. Takes
/// the already batch-loaded `APIUser?` (nil when the sweep found no such user)
/// and the course's classlist identity map — nil when the classlist read failed.
///
/// Resolution matches the classlist by **username first, student number
/// second** — the username is the identity Chickadee always has (SSO or local)
/// and equals the LEARN username at UW, so grade sync works without a
/// student-number claim.
///
/// A *populated* classlist is the authority on who can receive a grade in this
/// org unit. When it was read successfully, has members, and the student isn't
/// among them, resolution stops there rather than falling through to the
/// org-level `users/?orgDefinedId=` lookup: that lookup is LMS-GLOBAL and
/// happily returns the account of a student who is not enrolled in this course,
/// whose grade push D2L then rejects with a bare HTTP 404 that names no cause.
/// Returning nil instead surfaces it as the roster problem it is.
///
/// An index that is nil (read failed) or empty (e.g. a Valence key without
/// classlist permission) is NOT an authoritative "not here" — the global
/// fallback still runs there, so a classlist outage can't strand every push.
private func resolvedBrightSpaceUserID(
    for user: APIUser?,
    identityIndex: BrightSpaceIdentityIndex?,
    db: Database,
    client: any BrightSpaceGrading,
    application: Application
) async throws -> String? {
    guard let user else { return nil }

    if let cached = user.brightspaceUserID, !cached.isEmpty {
        return cached
    }

    var bsUserID = identityIndex?.d2lUserID(username: user.username, studentID: user.studentID)

    if bsUserID == nil {
        // Only a populated classlist can answer "this student isn't in the
        // course"; anything else means we have no roster to trust.
        let classlistIsAuthoritative = (identityIndex.map { !$0.isEmpty }) ?? false
        if classlistIsAuthoritative { return nil }

        guard let orgDefinedId = user.studentID, !orgDefinedId.isEmpty else { return nil }
        bsUserID = try await client.lookupUserID(orgDefinedId: orgDefinedId, on: application)
    }

    if let bsUserID {
        user.brightspaceUserID = bsUserID
        try await user.save(on: db)
    }
    return bsUserID
}

// MARK: - Push targets

/// One (student, test setup) grade push — several pending results can map to
/// the same key, in which case they're pushed once as a group.
struct GradePushKey: Hashable {
    let userID: UUID
    let testSetupID: String
}

/// Everything `pushGrade` needs for one group, pre-resolved from the
/// sweep-wide batch context.  `assignment` / `course` / `user` stay optional:
/// a missing row takes the same no-op / skip path the per-result lookups did.
///
/// `pendingOverride` is set only for an override-only target — a student with
/// no submissions whose grade comes entirely from an instructor override, so
/// there is no result row and the override row itself carries the pending flag.
private struct GradePushTarget {
    let userID: UUID
    let testSetupID: String
    let results: [APIResult]
    let pendingOverride: APIGradeOverride?
    let assignment: APIAssignment?
    let course: APICourse?
    let user: APIUser?

    /// Every row whose BrightSpace sync flags this push must update — the
    /// flagged result rows plus, for an override-only target, the override row.
    var syncRows: [any BrightSpaceSyncFlaggable] {
        var rows: [any BrightSpaceSyncFlaggable] = results
        if let pendingOverride { rows.append(pendingOverride) }
        return rows
    }
}

// MARK: - Batch loading

/// Sweep-wide lookup tables, loaded once per sweep.
struct GradeSyncBatchContext {
    let submissionsByID: [String: APISubmission]
    let assignmentsBySetupID: [String: APIAssignment]
    let coursesByID: [UUID: APICourse]
    let usersByID: [UUID: APIUser]
}

/// `~~` (SQL IN) filters take one chunk at a time so a very large pending
/// backlog can't exceed the driver's bind-parameter limit.
private let gradeSyncInFilterChunkSize = 5000

extension GradeSyncSweep {
    /// Batch-loads, once per sweep, every row the per-result pushes used to look
    /// up individually: the pending results' submissions, then the distinct
    /// assignments (by test setup), courses, and users they reference.
    private func loadGradeSyncBatchContext(
        for pending: [APIResult]
    ) async throws -> GradeSyncBatchContext {
        let submissionIDs = Array(Set(pending.map(\.submissionID)))
        var submissionsByID: [String: APISubmission] = [:]
        for chunk in chunkedForInFilter(submissionIDs) {
            for submission in try await APISubmission.query(on: db).filter(\.$id ~~ chunk).all() {
                guard let id = submission.id else { continue }
                submissionsByID[id] = submission
            }
        }

        // The assignment / course / user loading is identical to the
        // override-driven path — delegate to it with the keys the submissions
        // reference.
        let shared = try await loadSyncContextForKeys(
            setupIDs: submissionsByID.values.map(\.testSetupID),
            userIDs: submissionsByID.values.compactMap(\.userID))

        return GradeSyncBatchContext(
            submissionsByID: submissionsByID,
            assignmentsBySetupID: shared.assignmentsBySetupID,
            coursesByID: shared.coursesByID,
            usersByID: shared.usersByID
        )
    }

    /// Loads the assignments / courses / users a push set references, keyed for
    /// `GradePushTarget` assembly.  Starts from (test setup, user) keys — which
    /// override and grade-clear rows carry directly — so no submission lookup is
    /// needed; the result-driven `loadGradeSyncBatchContext` loads submissions
    /// first and then delegates here.
    func loadSyncContextForKeys(
        setupIDs rawSetupIDs: [String],
        userIDs rawUserIDs: [UUID]
    ) async throws -> GradeSyncBatchContext {
        let setupIDs = Array(Set(rawSetupIDs))
        var assignmentsBySetupID: [String: APIAssignment] = [:]
        for chunk in chunkedForInFilter(setupIDs) {
            // Keep one assignment per test setup — mirrors the previous
            // per-result `.first()` lookup.
            for assignment in try await APIAssignment.query(on: db).filter(\.$testSetupID ~~ chunk)
                .all()
            where assignmentsBySetupID[assignment.testSetupID] == nil {
                assignmentsBySetupID[assignment.testSetupID] = assignment
            }
        }

        let courseIDs = Array(Set(assignmentsBySetupID.values.map(\.courseID)))
        var coursesByID: [UUID: APICourse] = [:]
        for chunk in chunkedForInFilter(courseIDs) {
            for course in try await APICourse.query(on: db).filter(\.$id ~~ chunk).all() {
                guard let id = course.id else { continue }
                coursesByID[id] = course
            }
        }

        let userIDs = Array(Set(rawUserIDs))
        var usersByID: [UUID: APIUser] = [:]
        for chunk in chunkedForInFilter(userIDs) {
            for user in try await APIUser.query(on: db).filter(\.$id ~~ chunk).all() {
                guard let id = user.id else { continue }
                usersByID[id] = user
            }
        }

        return GradeSyncBatchContext(
            submissionsByID: [:],
            assignmentsBySetupID: assignmentsBySetupID,
            coursesByID: coursesByID,
            usersByID: usersByID
        )
    }
}

/// Splits an `~~` (SQL IN) filter's operand into driver-safe chunks. Shared with
/// the class-goal freeze re-push, which builds the same shape of query.
func chunkedForInFilter<T>(_ items: [T]) -> [[T]] {
    guard items.count > gradeSyncInFilterChunkSize else {
        return items.isEmpty ? [] : [items]
    }
    return stride(from: 0, to: items.count, by: gradeSyncInFilterChunkSize).map {
        Array(items[$0..<min($0 + gradeSyncInFilterChunkSize, items.count)])
    }
}

// MARK: - Per-sweep caches

/// Per-sweep cache of each course's LEARN classlist, reduced to the shared
/// `BrightSpaceIdentityIndex` (#1117 — one classlist reduction for grade
/// push, section sync, and the roster reconciler). Fetched once per org unit
/// per sweep.
actor ClasslistUserIDCache {
    private var indexByOrgUnit: [String: BrightSpaceIdentityIndex] = [:]

    /// The org unit's classlist as a `BrightSpaceIdentityIndex`. Fetched once
    /// per org unit per sweep; subsequent calls return the cached index.
    func identityIndex(
        orgUnitID: String, client: any BrightSpaceGrading, application: Application
    ) async throws -> BrightSpaceIdentityIndex {
        if let cached = indexByOrgUnit[orgUnitID] { return cached }
        let classlist = try await client.fetchClasslist(orgUnitID: orgUnitID, on: application)
        let index = BrightSpaceIdentityIndex(classlist: classlist)
        indexByOrgUnit[orgUnitID] = index
        return index
    }
}

/// Per-sweep cache of grade-item metadata, keyed by (org unit, grade object).
/// Fetched once per item per sweep so a backlog of pushes to the same
/// assignment shares one lookup. A cached `nil` (item not found) is preserved
/// distinctly from "not yet fetched".
actor GradeObjectInfoCache {
    private var cache: [String: BrightSpaceGradeObject?] = [:]

    func info(
        orgUnitID: String, gradeObjectID: String,
        client: any BrightSpaceGrading, application: Application
    ) async throws -> BrightSpaceGradeObject? {
        let key = "\(orgUnitID)\u{1f}\(gradeObjectID)"
        if let cached = cache[key] { return cached }
        let info = try await client.fetchGradeObject(
            orgUnitID: orgUnitID, gradeObjectID: gradeObjectID, on: application)
        cache[key] = info
        return info
    }
}

// MARK: - Monitor (reuses the shared PeriodicSweepMonitor scaffolding)

/// Grade-sync sweep cadence: 60 seconds. The debounce window (default 90 s) is
/// applied per row inside the sweep, not by the cadence.
private let brightSpaceGradeSyncInterval: TimeInterval = 60

struct BrightSpaceGradeSyncMonitorKey: StorageKey {
    typealias Value = PeriodicSweepMonitor
}

extension Application {
    /// The grade-sync periodic sweep, built on the shared
    /// `PeriodicSweepMonitor`. Registered via `PeriodicSweepLifecycleHandler`
    /// in `AppServices`, only when the deployment app credentials are present.
    ///
    /// The identity is resolved per course each cycle (not captured once), so
    /// a fresh connect / re-designation takes effect within one sweep interval
    /// without a restart. The sweep no-ops when BrightSpace isn't configured
    /// at the app level; each push resolves the course's designated instructor
    /// (or the deployment-wide fallback), deferring courses with no identity
    /// connected yet.
    var brightSpaceGradeSyncMonitor: PeriodicSweepMonitor {
        get {
            if let existing = storage[BrightSpaceGradeSyncMonitorKey.self] { return existing }
            let created = PeriodicSweepMonitor(
                name: "BrightSpace grade sync",
                interval: brightSpaceGradeSyncInterval,
                runImmediately: false
            ) { application in
                guard let app = application.brightSpaceAppCredentials else { return }
                let debounce = application.brightSpaceSyncConfig?.debounceSecs ?? app.debounceSecs
                let n = try await sweepBrightSpaceGradeSync(
                    on: application.db,
                    debounceSecs: debounce,
                    resolveClient: { course in
                        try await application.brightSpaceClient(forCourse: course)
                    },
                    logger: application.logger,
                    application: application
                )
                if n > 0 {
                    application.logger.info("BrightSpace grade sync: pushed \(n) grade(s)")
                }
            }
            storage[BrightSpaceGradeSyncMonitorKey.self] = created
            return created
        }
        set { storage[BrightSpaceGradeSyncMonitorKey.self] = newValue }
    }

    var brightSpaceSyncConfig: BrightSpaceSyncConfig? {
        get { storage[BrightSpaceSyncConfigKey.self] }
        set { storage[BrightSpaceSyncConfigKey.self] = newValue }
    }
}

struct BrightSpaceSyncConfigKey: StorageKey {
    typealias Value = BrightSpaceSyncConfig
}

/// The sync-log `detail` string for a rejected grade push. Deliberately takes
/// no points value: the pushed grade is a student's mark, and this string is
/// surfaced verbatim by the admin diagnostic MCP surface
/// (`get_brightspace_sync_status` error samples and the `get_health_alerts`
/// brightspace rule's `last_error`) — the grade lives only in the `points`
/// column, which those tools deliberately omit (compliance audit F-2). The
/// error text is safe to embed because `BrightSpaceSyncError.description`
/// omits the orgDefinedId and truncates D2L bodies.
func brightspacePushRejectionDetail(itemName: String, maxPoints: String, error: Error) -> String {
    "Grade push to '\(itemName)' (max \(maxPoints)) rejected: \(error.localizedDescription)"
}
