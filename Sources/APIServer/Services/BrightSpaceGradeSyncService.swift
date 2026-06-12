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
    client: BrightSpaceAPIClient,
    config: BrightSpaceSyncConfig,
    logger: Logger,
    application: Application,
    now: Date = Date()
) async throws -> Int {
    let cutoff = now.addingTimeInterval(-config.debounceSecs)

    // All results that are past the debounce window.
    let pending = try await APIResult.query(on: db)
        .filter(\.$brightspaceSyncPending == true)
        .filter(\.$brightspacePendingSince <= cutoff)
        .all()

    guard !pending.isEmpty else { return 0 }

    let context = try await loadGradeSyncBatchContext(for: pending, db: db)

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

    for key in groupOrder {
        guard let results = groups[key] else { continue }
        let assignment = context.assignmentsBySetupID[key.testSetupID]
        let target = GradePushTarget(
            userID: key.userID,
            testSetupID: key.testSetupID,
            results: results,
            assignment: assignment,
            course: assignment.flatMap { context.coursesByID[$0.courseID] },
            user: context.usersByID[key.userID]
        )
        do {
            try await pushGrade(for: target, db: db, client: client, logger: logger, application: application)
            processed += results.count
        } catch {
            await recordSweepFailure(results, error: error, db: db, logger: logger)
        }
    }
    return processed
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
private struct GradePushTarget {
    let userID: UUID
    let testSetupID: String
    let results: [APIResult]
    let assignment: APIAssignment?
    let course: APICourse?
    let user: APIUser?
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

/// Marks every result in a failed group the way the single-result error path
/// did: flag cleared, error recorded, push retried on the next pending cycle.
private func recordSweepFailure(
    _ results: [APIResult],
    error: Error,
    db: Database,
    logger: Logger
) async {
    for result in results {
        result.brightspaceSyncPending = false
        result.brightspaceSyncedAt = nil
        result.brightspaceSyncError = error.localizedDescription
        try? await result.save(on: db)
    }
    let ids = results.map { $0.id ?? "?" }.joined(separator: ", ")
    logger.warning("BrightSpace grade sync failed for result(s) \(ids): \(error)")
}

/// Clears the pending flag on every result in the group (the "nothing to
/// push" no-op outcome).
private func clearPendingFlag(_ results: [APIResult], on db: Database) async throws {
    for result in results {
        result.brightspaceSyncPending = false
        try await result.save(on: db)
    }
}

private func pushGrade(
    for target: GradePushTarget,
    db: Database,
    client: BrightSpaceAPIClient,
    logger: Logger,
    application: Application
) async throws {
    let userID = target.userID
    let testSetupID = target.testSetupID

    // The assignment for this test setup must have a grade item configured.
    guard let assignment = target.assignment,
        let gradeObjectID = assignment.brightspaceGradeObjectID,
        !gradeObjectID.isEmpty
    else {
        // No BrightSpace grade item configured — no-op.
        try await clearPendingFlag(target.results, on: db)
        return
    }

    // The course must have an org unit ID.
    guard let course = target.course,
        let orgUnitID = course.brightspaceOrgUnitID,
        !orgUnitID.isEmpty
    else {
        try await clearPendingFlag(target.results, on: db)
        return
    }

    // Best grade for this student across the test setup. nil → no submissions
    // yet (nothing to push); throws if submissions exist but yield no points.
    guard let points = try await bestPointsForStudent(userID: userID, testSetupID: testSetupID, db: db)
    else {
        try await clearPendingFlag(target.results, on: db)
        return
    }

    // Username snapshot for the sync log (readable without a join).
    let username = target.user?.username ?? userID.uuidString

    // Appends one row to the sync log. Best-effort: a logging failure must
    // never abort or retry a grade push, so errors are swallowed. Captures
    // the surrounding push context so callers pass only status + detail.
    func appendSyncLog(_ status: APIBrightSpaceSyncLog.Status, detail: String?) async {
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

    // Resolve D2L user ID (cached on APIUser, looked up on first sync).
    let bsUserID = try await resolvedBrightSpaceUserID(
        for: target.user,
        db: db,
        client: client,
        application: application
    )
    guard let bsUserID else {
        // No BrightSpace account for this student — record + skip.
        for result in target.results {
            result.brightspaceSyncPending = false
            result.brightspaceSyncError = "Student has no BrightSpace account (orgDefinedId not found)"
            try await result.save(on: db)
        }
        await appendSyncLog(.skipped, detail: "No BrightSpace account (orgDefinedId not found)")
        return
    }

    // Push the grade.
    do {
        try await client.pushGrade(
            orgUnitID: orgUnitID,
            gradeObjectID: gradeObjectID,
            bsUserID: bsUserID,
            earnedPoints: points,
            on: application
        )
    } catch {
        // Log with full context here (the sweep's catch lacks it), then
        // rethrow so the existing per-group error handling still runs.
        await appendSyncLog(.error, detail: error.localizedDescription)
        throw error
    }

    let syncedAt = Date()
    for result in target.results {
        result.brightspaceSyncPending = false
        result.brightspacePendingSince = nil
        result.brightspaceSyncedAt = syncedAt
        result.brightspaceSyncError = nil
        try await result.save(on: db)
    }

    await appendSyncLog(.success, detail: nil)

    logger.info("BrightSpace grade synced: user \(userID) assignment '\(assignment.title)' → \(points) pts")
}

/// Best (max) points for this student across all results for the test setup,
/// preferring worker results over browser ones.  Returns nil when the student
/// has no submissions yet (nothing to push); throws `.missingPoints` when
/// submissions exist but none yielded a parseable grade.
private func bestPointsForStudent(
    userID: UUID,
    testSetupID: String,
    db: Database
) async throws -> Double? {
    // An instructor override replaces the runner-derived grade. It stores a
    // percent, so it needs a points denominator: the suite's total possible
    // points (the BrightSpace grade item's max).
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

    guard !submissionIDs.isEmpty else {
        // No submissions yet. Only an override gives us anything to push.
        guard let override else { return nil }
        guard let total = try await suiteTotalPoints(testSetupID: testSetupID, db: db) else {
            return nil
        }
        return Double(override.overridePercent) / 100.0 * total
    }

    let allResults = try await APIResult.query(on: db)
        .filter(\.$submissionID ~~ submissionIDs)
        .all()
    // Prefer worker results; fall back to browser results for best-grade computation.
    let workerResults = allResults.filter { $0.source != "browser" }
    let resultsForGrade = workerResults.isEmpty ? allResults : workerResults

    if let override {
        // Prefer the suite manifest's total; fall back to the best result's
        // recorded totalPoints for setups whose manifest is unavailable.
        let total =
            try await suiteTotalPoints(testSetupID: testSetupID, db: db)
            ?? resultsForGrade.compactMap { $0.gradeTotalPointsValue }.max()
        guard let total, total > 0 else { throw BrightSpaceSyncError.missingPoints }
        return Double(override.overridePercent) / 100.0 * total
    }

    guard
        let points =
            resultsForGrade
            .compactMap({ $0.gradePointsValue })
            .max()
    else {
        throw BrightSpaceSyncError.missingPoints
    }
    // Class-goal bonus: extra credit, capped at the suite total (100%).
    let bonus = try await classGoalBonusPoints(testSetupID: testSetupID, on: db)
    if bonus > 0, let total = try await suiteTotalPoints(testSetupID: testSetupID, db: db) {
        return min(total, points + bonus)
    }
    return points
}

/// Total possible points for a test setup — the sum of its suite items'
/// weights, which is the BrightSpace grade item's max.  Nil when the manifest
/// is missing/malformed or sums to zero.
private func suiteTotalPoints(testSetupID: String, db: Database) async throws -> Double? {
    guard let setup = try await APITestSetup.find(testSetupID, on: db),
        let props = setup.decodedManifest()
    else {
        return nil
    }
    let total = props.testSuites.map(\.points).reduce(0, +)
    return total > 0 ? Double(total) : nil
}

/// Returns the cached D2L user ID for `user`, looking it up via studentID if
/// not yet cached.  Takes the already batch-loaded `APIUser?` (nil when the
/// sweep found no such user — same outcome as the old per-result `find`).
private func resolvedBrightSpaceUserID(
    for user: APIUser?,
    db: Database,
    client: BrightSpaceAPIClient,
    application: Application
) async throws -> String? {
    guard let user else { return nil }

    if let cached = user.brightspaceUserID, !cached.isEmpty {
        return cached
    }

    // Look up by studentID (= BrightSpace OrgDefinedId).
    guard let orgDefinedId = user.studentID, !orgDefinedId.isEmpty else {
        return nil
    }

    let bsUserID = try await client.lookupUserID(orgDefinedId: orgDefinedId, on: application)

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
        guard task == nil,
            let client = application.brightSpaceClient,
            let config = application.brightSpaceSyncConfig
        else { return }

        task = Task {
            while !Task.isCancelled {
                do {
                    let n = try await sweepBrightSpaceGradeSync(
                        on: application.db,
                        client: client,
                        config: config,
                        logger: application.logger,
                        application: application
                    )
                    if n > 0 {
                        application.logger.info("BrightSpace grade sync: pushed \(n) grade(s)")
                    }
                } catch {
                    application.logger.error("BrightSpace grade sync sweep failed: \(error.localizedDescription)")
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
