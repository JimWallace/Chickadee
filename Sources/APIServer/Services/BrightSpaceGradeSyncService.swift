// APIServer/Services/BrightSpaceGradeSyncService.swift
//
// Debounced BrightSpace grade-sync sweep.
//
// When a worker result is saved, ResultRoutes sets brightspace_sync_pending = true
// on the APIResult row.  This service polls every 60 seconds and pushes the best
// grade for each (student, assignment) pair whose pending flag has been set for
// longer than the configured debounce window (default 90 s).
//
// If BrightSpace is unreachable the error is recorded on the result row and the
// push retries on the next sweep — no work is lost.

import Fluent
import Foundation
import Vapor

// MARK: - Pure sweep function

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
    now: Date = Date()
) async throws -> Int {
    let cutoff = now.addingTimeInterval(-debounceSecs)

    // All results that are past the debounce window. May be empty — an
    // override on a student with no submissions has no result row, so the sweep
    // must still run the override scan below even when nothing here is pending.
    // (With an empty `pending`, loadGradeSyncBatchContext issues no queries and
    // the result loops don't execute, so there's no early-return short-circuit.)
    let pending = try await APIResult.query(on: db)
        .filter(\.$brightspaceSyncPending == true)
        .filter(\.$brightspacePendingSince <= cutoff)
        .all()

    let context = try await loadGradeSyncBatchContext(for: pending, db: db)

    var processed = 0

    // One classlist read per course, and one grade-object fetch per item, are
    // shared across all of this sweep's pushes.
    let classlistCache = ClasslistUserIDCache()
    let gradeObjectCache = GradeObjectInfoCache()

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
    targets += try await pendingOverrideTargets(
        coveredKeys: coveredKeys, cutoff: cutoff, db: db)

    for target in targets {
        let syncRows = target.syncRows
        do {
            let pushed = try await pushGrade(
                for: target, db: db, resolveClient: resolveClient,
                classlistCache: classlistCache, gradeObjectCache: gradeObjectCache,
                application: application)
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
        pushedKeys: pushedKeys, cutoff: cutoff, db: db,
        resolveClient: resolveClient, classlistCache: classlistCache, application: application)
    return processed
}

/// A queued grade removal plus the rows it needs, pre-resolved from the
/// sweep-wide batch context.
private struct GradeClearTarget {
    let clearRow: APIBrightSpaceGradeClear
    let assignment: APIAssignment?
    let course: APICourse?
    let user: APIUser?
}

/// Processes pending `brightspace_grade_clears`: DELETEs each student's grade in
/// D2L and removes the queue row on success. A clear whose (student, setup) is
/// also being pushed this sweep is dropped (the push wins). Returns the number
/// of clears completed.
private func processPendingGradeClears(
    pushedKeys: Set<GradePushKey>,
    cutoff: Date,
    db: Database,
    resolveClient: (APICourse) async throws -> (any BrightSpaceGrading)?,
    classlistCache: ClasslistUserIDCache,
    application: Application
) async throws -> Int {
    let pending = try await APIBrightSpaceGradeClear.query(on: db)
        .filter(\.$brightspaceSyncPending == true)
        .filter(\.$brightspacePendingSince <= cutoff)
        .all()
    guard !pending.isEmpty else { return 0 }

    let context = try await loadSyncContextForKeys(
        setupIDs: pending.map(\.testSetupID), userIDs: pending.map(\.userID), db: db)
    var processed = 0
    for clearRow in pending {
        let key = GradePushKey(userID: clearRow.userID, testSetupID: clearRow.testSetupID)
        if pushedKeys.contains(key) {
            // A grade is being (re)pushed for this (student, setup) — drop the clear.
            try await clearRow.delete(on: db)
            continue
        }
        let assignment = context.assignmentsBySetupID[clearRow.testSetupID]
        let target = GradeClearTarget(
            clearRow: clearRow,
            assignment: assignment,
            course: assignment.flatMap { context.coursesByID[$0.courseID] },
            user: context.usersByID[clearRow.userID]
        )
        do {
            let cleared = try await runGradeClear(
                target: target, resolveClient: resolveClient,
                classlistCache: classlistCache, db: db, application: application)
            if cleared { processed += 1 }
        } catch {
            await recordSweepFailure([clearRow], error: error, db: db, logger: application.logger)
        }
    }
    return processed
}

/// Removes one student's grade in D2L. Returns false when deferred (no identity
/// connected yet) so the row stays pending; true on every terminal outcome
/// (cleared, or a no-op delete because there was nothing in D2L to clear).
private func runGradeClear(
    target: GradeClearTarget,
    resolveClient: (APICourse) async throws -> (any BrightSpaceGrading)?,
    classlistCache: ClasslistUserIDCache,
    db: Database,
    application: Application
) async throws -> Bool {
    let clearRow = target.clearRow
    // Without a configured grade item + org unit there is nothing in D2L to
    // clear — drop the queue row.
    guard let assignment = target.assignment,
        let gradeObjectID = assignment.brightspaceGradeObjectID, !gradeObjectID.isEmpty,
        let course = target.course,
        let orgUnitID = course.brightspaceOrgUnitID, !orgUnitID.isEmpty
    else {
        try await clearRow.delete(on: db)
        return true
    }
    // A grade source may have reappeared since the clear was queued — the
    // student submitted, or a new override was set. If so, drop the clear; the
    // normal push path will (re)set their grade instead of us removing it.
    if try await studentHasGradeSource(
        testSetupID: clearRow.testSetupID, userID: clearRow.userID, db: db)
    {
        try await clearRow.delete(on: db)
        return true
    }

    // Defer until the course has a connected sync identity.
    guard let client = try await resolveClient(course) else { return false }

    let bsUserID = try await resolveBSUserID(
        for: target.user, orgUnitID: orgUnitID, client: client,
        classlistCache: classlistCache, db: db, application: application)
    guard let bsUserID else {
        // No D2L account resolves — nothing to clear.
        try await clearRow.delete(on: db)
        return true
    }

    try await client.clearGrade(
        orgUnitID: orgUnitID, gradeObjectID: gradeObjectID, bsUserID: bsUserID, on: application)

    let entry = APIBrightSpaceSyncLog(
        courseID: course.id, testSetupID: assignment.testSetupID,
        assignmentTitle: assignment.title, userID: clearRow.userID,
        username: target.user?.username ?? clearRow.userID.uuidString,
        orgUnitID: orgUnitID, gradeObjectID: gradeObjectID, points: nil,
        status: .success, detail: "Grade cleared in BrightSpace")
    try? await entry.save(on: db)
    try await clearRow.delete(on: db)
    application.logger.info(
        "BrightSpace grade cleared: user \(clearRow.userID) assignment '\(assignment.title)'")
    return true
}

/// True when the student still has a Chickadee grade source for the setup — a
/// student submission or an instructor override — so a queued grade removal
/// must NOT run.
private func studentHasGradeSource(
    testSetupID: String, userID: UUID, db: Database
) async throws -> Bool {
    let hasSubmission =
        try await APISubmission.query(on: db)
        .filter(\.$userID == userID)
        .filter(\.$testSetupID == testSetupID)
        .filter(\.$kind == APISubmission.Kind.student)
        .first() != nil
    if hasSubmission { return true }
    return
        try await APIGradeOverride.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .filter(\.$userID == userID)
        .first() != nil
}

/// Builds override-only push targets from `grade_overrides` rows flagged
/// pending past the debounce cutoff.  A row whose (student, test setup) is
/// already covered by a result-driven group has its pending flag cleared in
/// place (the results path will push it) and yields no target.
private func pendingOverrideTargets(
    coveredKeys: Set<GradePushKey>,
    cutoff: Date,
    db: Database
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
        setupIDs: overrideOnly.map(\.testSetupID), userIDs: overrideOnly.map(\.userID), db: db)
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

/// Loads the assignments / courses / users an override-only push set
/// references, keyed for `GradePushTarget` assembly.  Mirrors the result-driven
/// `loadGradeSyncBatchContext` but starts from override rows (which already
/// carry the test setup + user), so no submission lookup is needed.
private func loadSyncContextForKeys(
    setupIDs rawSetupIDs: [String],
    userIDs rawUserIDs: [UUID],
    db: Database
) async throws -> GradeSyncBatchContext {
    let setupIDs = Array(Set(rawSetupIDs))
    var assignmentsBySetupID: [String: APIAssignment] = [:]
    for chunk in chunkedForInFilter(setupIDs) {
        for assignment in try await APIAssignment.query(on: db).filter(\.$testSetupID ~~ chunk).all()
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

// MARK: - Batch loading

/// One (student, test setup) grade push — several pending results can map to
/// the same key, in which case they're pushed once as a group.
private struct GradePushKey: Hashable {
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

/// A row carrying the four BrightSpace grade-sync bookkeeping columns. Both
/// `APIResult` and `APIGradeOverride` conform, so the sweep's success / clear /
/// failure paths mark them identically regardless of which kind enqueued the
/// push.
protocol BrightSpaceSyncFlaggable: AnyObject {
    var brightspaceSyncPending: Bool? { get set }
    var brightspacePendingSince: Date? { get set }
    var brightspaceSyncedAt: Date? { get set }
    var brightspaceSyncError: String? { get set }
    /// Stable identifier for log lines (a result's string id / an override's UUID).
    var brightspaceSyncRowID: String { get }
    func save(on database: Database) async throws
}

extension APIResult: BrightSpaceSyncFlaggable {
    var brightspaceSyncRowID: String { id ?? "?" }
}

extension APIGradeOverride: BrightSpaceSyncFlaggable {
    var brightspaceSyncRowID: String { id?.uuidString ?? "?" }
}

extension APIBrightSpaceGradeClear: BrightSpaceSyncFlaggable {
    var brightspaceSyncRowID: String { id?.uuidString ?? "?" }
}

/// Sweep-wide lookup tables, loaded once per sweep.
private struct GradeSyncBatchContext {
    let submissionsByID: [String: APISubmission]
    let assignmentsBySetupID: [String: APIAssignment]
    let coursesByID: [UUID: APICourse]
    let usersByID: [UUID: APIUser]
}

/// `~~` (SQL IN) filters take one chunk at a time so a very large pending
/// backlog can't exceed the driver's bind-parameter limit.
private let gradeSyncInFilterChunkSize = 5000

/// Batch-loads, once per sweep, every row the per-result pushes used to look
/// up individually: the pending results' submissions, then the distinct
/// assignments (by test setup), courses, and users they reference.
private func loadGradeSyncBatchContext(
    for pending: [APIResult],
    db: Database
) async throws -> GradeSyncBatchContext {
    let submissionIDs = Array(Set(pending.map(\.submissionID)))
    var submissionsByID: [String: APISubmission] = [:]
    for chunk in chunkedForInFilter(submissionIDs) {
        for submission in try await APISubmission.query(on: db).filter(\.$id ~~ chunk).all() {
            guard let id = submission.id else { continue }
            submissionsByID[id] = submission
        }
    }

    let setupIDs = Array(Set(submissionsByID.values.map(\.testSetupID)))
    var assignmentsBySetupID: [String: APIAssignment] = [:]
    for chunk in chunkedForInFilter(setupIDs) {
        // Keep one assignment per test setup — mirrors the previous
        // per-result `.first()` lookup.
        for assignment in try await APIAssignment.query(on: db).filter(\.$testSetupID ~~ chunk).all()
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

    let userIDs = Array(Set(submissionsByID.values.compactMap(\.userID)))
    var usersByID: [UUID: APIUser] = [:]
    for chunk in chunkedForInFilter(userIDs) {
        for user in try await APIUser.query(on: db).filter(\.$id ~~ chunk).all() {
            guard let id = user.id else { continue }
            usersByID[id] = user
        }
    }

    return GradeSyncBatchContext(
        submissionsByID: submissionsByID,
        assignmentsBySetupID: assignmentsBySetupID,
        coursesByID: coursesByID,
        usersByID: usersByID
    )
}

private func chunkedForInFilter<T>(_ items: [T]) -> [[T]] {
    guard items.count > gradeSyncInFilterChunkSize else {
        return items.isEmpty ? [] : [items]
    }
    return stride(from: 0, to: items.count, by: gradeSyncInFilterChunkSize).map {
        Array(items[$0..<min($0 + gradeSyncInFilterChunkSize, items.count)])
    }
}

// MARK: - Per-group push

/// True when a push failure is worth retrying automatically — a transient D2L
/// or transport hiccup — versus a terminal failure that will keep failing until
/// a human intervenes (a bad request, a missing account, no parseable grade).
///
/// HTTP 408/425/429 and 5xx are transient; other 4xx are terminal. A
/// `missingPoints`/lookup `BrightSpaceSyncError` is terminal (the grade or item
/// won't fix itself on retry). Anything else — a raw transport/NIO error from
/// the signed request — is treated as transient.
func isRetryableSyncError(_ error: Error) -> Bool {
    if let syncError = error as? BrightSpaceSyncError {
        switch syncError {
        case .gradePushFailed(let status, _):
            return [408, 425, 429, 500, 502, 503, 504].contains(status)
        default:
            // missingPoints / userLookupFailed / orgUnitLookupFailed /
            // gradeObjectsFetchFailed — none retry into success on their own.
            return false
        }
    }
    // Non-BrightSpaceSyncError: a transport/timeout error from the HTTP call.
    return true
}

/// Records a failed group. A transient (retryable) failure keeps the pending
/// flag set so the next sweep re-attempts it automatically; a terminal failure
/// clears the flag and waits for a manual "Retry failed". Either way the error
/// detail is recorded and the synced timestamp cleared.
private func recordSweepFailure(
    _ rows: [any BrightSpaceSyncFlaggable],
    error: Error,
    db: Database,
    logger: Logger
) async {
    let retryable = isRetryableSyncError(error)
    for row in rows {
        row.brightspaceSyncPending = retryable
        row.brightspaceSyncedAt = nil
        row.brightspaceSyncError = error.localizedDescription
        try? await row.save(on: db)
    }
    let ids = rows.map(\.brightspaceSyncRowID).joined(separator: ", ")
    logger.warning(
        "BrightSpace grade sync \(retryable ? "transient" : "terminal") failure for row(s) \(ids): \(error)")
}

/// Clears the pending flag on every row in the group (the "nothing to
/// push" no-op outcome).
private func clearPendingFlag(_ rows: [any BrightSpaceSyncFlaggable], on db: Database) async throws {
    for row in rows {
        row.brightspaceSyncPending = false
        try await row.save(on: db)
    }
}

/// Pushes one group's grade. Returns false when the push is *deferred* (the
/// course has no grade-sync identity connected yet) so the caller leaves the
/// rows pending for a later sweep; true on every terminal outcome (pushed,
/// skipped, or a no-op flag clear).
@discardableResult
private func pushGrade(
    for target: GradePushTarget,
    db: Database,
    resolveClient: (APICourse) async throws -> (any BrightSpaceGrading)?,
    classlistCache: ClasslistUserIDCache,
    gradeObjectCache: GradeObjectInfoCache,
    application: Application
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
    guard let grade = try await bestGradeForStudent(userID: userID, testSetupID: testSetupID, db: db)
    else {
        try await clearPendingFlag(syncRows, on: db)
        return true
    }

    // Username snapshot for the sync log (readable without a join).
    let username = target.user?.username ?? userID.uuidString

    // Appends one row to the sync log. Best-effort: a logging failure must
    // never abort or retry a grade push, so errors are swallowed. Captures
    // the surrounding push context so callers pass only status + points + detail.
    func appendSyncLog(_ status: APIBrightSpaceSyncLog.Status, points: Double, detail: String?) async {
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

    let bsUserID = try await resolveBSUserID(
        for: target.user, orgUnitID: orgUnitID, client: client,
        classlistCache: classlistCache, db: db, application: application)
    guard let bsUserID else {
        try await recordTerminalSkip(
            "Student has no BrightSpace account (orgDefinedId not found)", points: pushPoints)
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
        // Enrich with item context here (the sweep's catch lacks it), then
        // rethrow so the existing per-group error handling still runs.
        let maxDesc = gradeObject?.maxPoints.map { "\($0)" } ?? "unset"
        await appendSyncLog(
            .error, points: pushPoints,
            detail: "Pushed \(pushPoints) pts to '\(gradeObject?.name ?? gradeObjectID)' "
                + "(max \(maxDesc)); D2L rejected it: \(error.localizedDescription)")
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

/// The points to push and the grade item they target, or a `refusal` message
/// when the item can't be synced to (non-numeric). Fetches the grade item once
/// (cached) and scales the grade onto its max; a fetch failure degrades to "no
/// scaling, no type check" so a push that would otherwise work isn't blocked.
private func scaledGradePush(
    grade: StudentGrade,
    orgUnitID: String,
    gradeObjectID: String,
    client: any BrightSpaceGrading,
    gradeObjectCache: GradeObjectInfoCache,
    application: Application
) async -> (pushPoints: Double, gradeObject: BrightSpaceGradeObject?, refusal: String?) {
    var gradeObject: BrightSpaceGradeObject?
    do {
        gradeObject = try await gradeObjectCache.info(
            orgUnitID: orgUnitID, gradeObjectID: gradeObjectID, client: client, application: application)
    } catch {
        application.logger.warning("BrightSpace grade-object fetch failed for \(gradeObjectID): \(error)")
    }

    // Refuse a non-numeric / category item with a clear message rather than a
    // bare D2L 400 — Chickadee only writes point values to Numeric items.
    if let type = gradeObject?.gradeType, !type.isEmpty,
        type.caseInsensitiveCompare("Numeric") != .orderedSame
    {
        let message =
            "Grade item '\(gradeObject?.name ?? gradeObjectID)' is type \(type); "
            + "Chickadee can only sync to Numeric grade items."
        return (grade.points, gradeObject, message)
    }

    // Scale Chickadee's grade onto the D2L item's own max when both totals are
    // known (e.g. a /14 suite into a /10 LEARN item). When the item's max is
    // unknown or already equals the suite total, this is the identity, so the
    // pushed value is unchanged. The result is rounded to 2 decimals so the
    // gradebook shows a clean value (8.57) rather than 8.571428571…
    if let total = grade.total, total > 0, let maxPoints = gradeObject?.maxPoints, maxPoints > 0 {
        return (roundedGradePoints(grade.points / total * maxPoints), gradeObject, nil)
    }
    return (roundedGradePoints(grade.points), gradeObject, nil)
}

/// Rounds a grade value to 2 decimal places for the LEARN gradebook.
private func roundedGradePoints(_ value: Double) -> Double {
    (value * 100).rounded() / 100
}

/// Resolves the student's D2L user ID via the course classlist (cached per
/// sweep), falling back to the org-level OrgDefinedId lookup. A classlist read
/// failure degrades to the fallback rather than aborting the push.
private func resolveBSUserID(
    for user: APIUser?,
    orgUnitID: String,
    client: any BrightSpaceGrading,
    classlistCache: ClasslistUserIDCache,
    db: Database,
    application: Application
) async throws -> String? {
    var identityMap: [String: String] = [:]
    do {
        identityMap = try await classlistCache.identityMap(
            orgUnitID: orgUnitID, client: client, application: application)
    } catch {
        application.logger.warning("BrightSpace classlist resolve failed for org unit \(orgUnitID): \(error)")
    }
    return try await resolvedBrightSpaceUserID(
        for: user, identityMap: identityMap, db: db, client: client, application: application)
}

/// One student's best grade for a test setup: the raw points Chickadee would
/// push (in suite-point units) plus the denominator (suite total) used to
/// derive them, so the caller can rescale to the BrightSpace grade item's own
/// max. `total` is nil only when neither the manifest nor any result records a
/// total.
private struct StudentGrade {
    let points: Double
    let total: Double?
}

/// Best (max) grade for this student across all results for the test setup,
/// preferring worker results over browser ones.  Returns nil when the student
/// has no submissions yet (nothing to push); throws `.missingPoints` when
/// submissions exist but none yielded a parseable grade.
private func bestGradeForStudent(
    userID: UUID,
    testSetupID: String,
    db: Database
) async throws -> StudentGrade? {
    // An instructor override replaces the runner-derived grade. It stores a
    // percent, so it needs a points denominator: the suite's total possible
    // points.
    let override = try await APIGradeOverride.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .filter(\.$userID == userID)
        .first()

    let submissionIDs = try await APISubmission.query(on: db)
        .filter(\.$userID == userID)
        .filter(\.$testSetupID == testSetupID)
        .filter(\.$kind == APISubmission.Kind.student)
        .all()
        .compactMap(\.id)

    let manifestTotal = try await suiteTotalPoints(testSetupID: testSetupID, db: db)

    guard !submissionIDs.isEmpty else {
        // No submissions yet. Only an override gives us anything to push.
        guard let override else { return nil }
        guard let total = manifestTotal else { return nil }
        return StudentGrade(points: Double(override.overridePercent) / 100.0 * total, total: total)
    }

    if let override {
        let total: Double?
        if let mt = manifestTotal {
            total = mt
        } else {
            total = try await APIResult.query(on: db)
                .filter(\.$submissionID ~~ submissionIDs)
                .all()
                .compactMap { $0.gradeTotalPointsValue }.max()
        }
        guard let total, total > 0 else { throw BrightSpaceSyncError.missingPoints }
        return StudentGrade(points: Double(override.overridePercent) / 100.0 * total, total: total)
    }

    // Highest grade wins across ALL result sources (browser + worker alike): a
    // 100 % browser result is never displaced by a later lower worker re-grade,
    // matching the grades CSV / dashboard / roster surfaces.  Pick the result
    // with the highest percent, then push its EXACT points so the LEARN value
    // isn't degraded by integer-percent rounding (the shared
    // `bestGradePercentBySubmissionID` helper returns an Int percent, which is
    // fine for the display surfaces but lossy for a points push, e.g. 6/7 → 86 %
    // → 8.6 instead of 8.57).
    let allResults = try await APIResult.query(on: db)
        .filter(\.$submissionID ~~ submissionIDs)
        .all()
    guard
        let best =
            allResults
            .filter({ $0.gradePercentValue != nil })
            .max(by: { ($0.gradePercentValue ?? 0) < ($1.gradePercentValue ?? 0) }),
        let earned = best.gradePointsValue
    else {
        throw BrightSpaceSyncError.missingPoints
    }
    // Denominator: prefer the manifest's suite total (stable, matches the grades
    // CSV); fall back to the winning result's own recorded total when the
    // manifest carries no per-suite points (mirrors the override branch above and
    // the pre-#1085 behaviour).
    let resultTotal = best.gradeTotalPointsValue
    guard let total = manifestTotal ?? resultTotal, total > 0 else {
        throw BrightSpaceSyncError.missingPoints
    }
    // Express the winning result's grade on the chosen denominator.  When the
    // result carries its own total, scale exactly (earned / resultTotal * total)
    // so integer-percent rounding never enters the pushed value; otherwise the
    // earned value is already in suite-point units (the pass-count fallback).
    let basePoints: Double
    if let resultTotal, resultTotal > 0 {
        basePoints = earned / resultTotal * total
    } else {
        basePoints = earned
    }
    // Class-goal bonus: extra credit, capped at the suite total (100%).
    let bonus = try await classGoalBonusPoints(testSetupID: testSetupID, on: db)
    let points = bonus > 0 ? min(total, basePoints + bonus) : basePoints
    return StudentGrade(points: points, total: total)
}

/// Total possible points for a test setup — the sum of its suite items'
/// weights.  Used as the denominator to rescale a grade onto the BrightSpace
/// grade item's own max.  Nil when the manifest is missing/malformed or sums to
/// zero.
private func suiteTotalPoints(testSetupID: String, db: Database) async throws -> Double? {
    guard let setup = try await APITestSetup.find(testSetupID, on: db),
        let props = setup.decodedManifest()
    else {
        return nil
    }
    let total = props.testSuites.map(\.points).reduce(0, +)
    return total > 0 ? Double(total) : nil
}

/// Per-sweep cache of each course's LEARN classlist, reduced to an identity →
/// D2L UserId map. The classlist carries both the student's login username and
/// their student number (OrgDefinedId), so a Chickadee user is resolved by
/// whichever identity is on file — username first (always present for SSO/local
/// logins, == the LEARN username at UW), student number second. Fetched once
/// per org unit per sweep.
private actor ClasslistUserIDCache {
    private var mapsByOrgUnit: [String: [String: String]] = [:]

    /// The org unit's classlist as an identity → D2L UserId map, keyed by both
    /// lowercased username and lowercased OrgDefinedId. Fetched once per org
    /// unit per sweep; subsequent calls return the cached map.
    func identityMap(
        orgUnitID: String, client: any BrightSpaceGrading, application: Application
    ) async throws -> [String: String] {
        if let cached = mapsByOrgUnit[orgUnitID] { return cached }
        let classlist = try await client.fetchClasslist(orgUnitID: orgUnitID, on: application)
        var map: [String: String] = [:]
        for entry in classlist {
            guard let userID = entry.userID, !userID.isEmpty else { continue }
            for identity in [entry.username, entry.orgDefinedID] {
                let key = identity?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if let key, !key.isEmpty { map[key] = userID }
            }
        }
        mapsByOrgUnit[orgUnitID] = map
        return map
    }
}

/// Per-sweep cache of grade-item metadata, keyed by (org unit, grade object).
/// Fetched once per item per sweep so a backlog of pushes to the same
/// assignment shares one lookup. A cached `nil` (item not found) is preserved
/// distinctly from "not yet fetched".
private actor GradeObjectInfoCache {
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

/// Returns the cached D2L user ID for `user`, resolving it on first sync. Takes
/// the already batch-loaded `APIUser?` (nil when the sweep found no such user)
/// and the course's pre-built classlist identity map.
///
/// Resolution matches the classlist by **username first, student number
/// second** — the username is the identity Chickadee always has (SSO or local)
/// and equals the LEARN username at UW, so grade sync works without a
/// student-number claim. Falls back to the org-level `users/?orgDefinedId=`
/// lookup only when the classlist match misses but a student number is on file.
private func resolvedBrightSpaceUserID(
    for user: APIUser?,
    identityMap: [String: String],
    db: Database,
    client: any BrightSpaceGrading,
    application: Application
) async throws -> String? {
    guard let user else { return nil }

    if let cached = user.brightspaceUserID, !cached.isEmpty {
        return cached
    }

    var bsUserID: String?
    for key in [user.username, user.studentID].compactMap({ $0 }) {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalized.isEmpty, let resolved = identityMap[normalized] {
            bsUserID = resolved
            break
        }
    }
    // Fallback: the legacy org-level OrgDefinedId lookup (needs a student number).
    if bsUserID == nil, let orgDefinedId = user.studentID, !orgDefinedId.isEmpty {
        bsUserID = try await client.lookupUserID(orgDefinedId: orgDefinedId, on: application)
    }

    if let bsUserID {
        user.brightspaceUserID = bsUserID
        try await user.save(on: db)
    }
    return bsUserID
}

// MARK: - Monitor

final class BrightSpaceGradeSyncMonitor: @unchecked Sendable {
    // @unchecked Sendable: the only mutable state (`task`) is touched solely
    // from start()/stop() on the app lifecycle (didBoot/shutdown), never
    // concurrently.
    private var task: Task<Void, Never>?
    private let sweepIntervalNanoseconds: UInt64 = 60 * 1_000_000_000

    func start(application: Application) {
        guard task == nil else { return }

        // The identity is resolved per course each cycle (not captured once), so
        // a fresh connect / re-designation takes effect within one sweep interval
        // without a restart. The loop runs whenever BrightSpace is configured at
        // the app level; each push resolves the course's designated instructor
        // (or the deployment-wide fallback), deferring courses with no identity
        // connected yet.
        task = Task {
            while !Task.isCancelled {
                if let app = application.brightSpaceAppCredentials {
                    let debounce = application.brightSpaceSyncConfig?.debounceSecs ?? app.debounceSecs
                    do {
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
                    } catch {
                        application.logger.error("BrightSpace grade sync sweep failed: \(error.localizedDescription)")
                    }
                }
                do {
                    try await Task.sleep(nanoseconds: sweepIntervalNanoseconds)
                } catch {
                    break
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

// MARK: - Lifecycle handler

struct BrightSpaceGradeSyncMonitorKey: StorageKey {
    typealias Value = BrightSpaceGradeSyncMonitor
}

struct BrightSpaceGradeSyncLifecycleHandler: LifecycleHandler {
    func didBoot(_ application: Application) throws {
        application.brightSpaceGradeSyncMonitor.start(application: application)
    }

    func shutdown(_ application: Application) {
        application.brightSpaceGradeSyncMonitor.stop()
    }
}

extension Application {
    var brightSpaceGradeSyncMonitor: BrightSpaceGradeSyncMonitor {
        get {
            if let existing = storage[BrightSpaceGradeSyncMonitorKey.self] { return existing }
            let created = BrightSpaceGradeSyncMonitor()
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
