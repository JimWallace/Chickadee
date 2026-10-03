// APIServer/BrightSpace/BrightSpaceGradeSyncService.swift
//
// BrightSpace sync-row bookkeeping shared by the sweep, the grade clears, and
// the manual "Sync now" routes: the `BrightSpaceSyncFlaggable` protocol (the
// sync flag columns `APIResult` / `APIGradeOverride` /
// `APIBrightSpaceGradeClear` all carry), the requeue / clear / failure-recording
// helpers, and the transient-vs-terminal retry classification.
//
// The flow: when a worker result is saved, ResultRoutes sets
// brightspace_sync_pending = true on the APIResult row.  The sweep
// (BrightSpaceSyncSweep.swift) polls every 60 seconds and pushes the best
// grade (BrightSpaceGradeSelection.swift) for each (student, assignment) pair
// whose pending flag has been set for longer than the configured debounce
// window (default 90 s).  If BrightSpace is unreachable the error is recorded
// on the row and the push retries on the next sweep — no work is lost.

import Fluent
import Foundation
import Vapor

// MARK: - Sync-row flags

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

// MARK: - Retry classification

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

// MARK: - Flag bookkeeping

/// Records a failed group. A transient (retryable) failure keeps the pending
/// flag set so the next sweep re-attempts it automatically; a terminal failure
/// clears the flag and waits for a manual "Sync now" (which re-queues errored
/// rows before sweeping). Either way the error detail is recorded and the synced
/// timestamp cleared.
func recordSweepFailure(
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
    // Row ids are result/override rows keyed to a student — metadata only, so
    // the admin query_logs buffer drops them at capture (compliance audit F-1).
    let ids = rows.map(\.brightspaceSyncRowID).joined(separator: ", ")
    logger.warning(
        "BrightSpace grade sync \(retryable ? "transient" : "terminal") failure for \(rows.count) row(s): \(error)",
        metadata: ["row_ids": .string(ids)])
}

/// Flags a freshly-built (not yet saved) result row for BrightSpace grade sync
/// when its assignment is actually wired to a LEARN grade item — the gate every
/// result-ingest path shares.
///
/// Mutates `result` in memory only; the caller persists it (both call sites save
/// the row immediately afterwards, so the flags ride along on the same INSERT).
///
/// This lives here, called from BOTH ingest paths, because it used to be inline
/// in the worker path only: browser-graded results were never flagged, so
/// notebook assignments never auto-pushed a grade to LEARN at all. Their grades
/// only appeared when an instructor hit "Push all" (or a retest routed the
/// submission through a worker), which looks exactly like "sync is broken for
/// this assignment" — the sweep had nothing to find.
///
/// Gates on app-level config (not a live global client) so per-instructor-only
/// deployments still flag results for the per-course sync to pick up.
func flagResultForBrightSpaceSync(
    _ result: APIResult,
    testSetupID: String,
    application: Application,
    on db: Database
) async throws {
    guard application.brightSpaceAppCredentials != nil else { return }
    guard
        let assignment = try await assignmentByTestSetupID(testSetupID, on: db),
        let gradeObjectID = assignment.brightspaceGradeObjectID,
        !gradeObjectID.isEmpty,
        let course = try await APICourse.find(assignment.courseID, on: db),
        let orgUnitID = course.brightspaceOrgUnitID,
        !orgUnitID.isEmpty,
        // A course on AGS never sends through Valence (docs/lti-1-3.md).
        !course.usesLTIGrades
    else { return }

    result.brightspaceSyncPending = true
    result.brightspacePendingSince = Date()
}

/// Re-queues rows for an immediate push: pending flag set, `pendingSince`
/// back-dated past any debounce cutoff, recorded error cleared. The ONE place
/// the `Date.distantPast` "retry immediately" sentinel is written (#1117) —
/// the manual "Sync now" / "Push all" routes used to copy-paste this
/// triple-write five times.
func requeueForImmediateSync(_ rows: [any BrightSpaceSyncFlaggable], on db: Database) async throws {
    for row in rows {
        row.brightspaceSyncPending = true
        row.brightspacePendingSince = Date.distantPast
        row.brightspaceSyncError = nil
        try await row.save(on: db)
    }
}

/// Clears the pending flag on every row in the group (the "nothing to
/// push" no-op outcome).
func clearPendingFlag(_ rows: [any BrightSpaceSyncFlaggable], on db: Database) async throws {
    for row in rows {
        row.brightspaceSyncPending = false
        try await row.save(on: db)
    }
}

// MARK: - Manual triggers ("Sync now", "Push all")

/// Clears the recorded error and re-flags as pending every grade-sync row in
/// the course (result rows, override-only rows, and queued grade clears)
/// that previously errored, back-dating `pendingSince` so the next sweep
/// retries it immediately. The "hard reset" half of "Sync now".
func requeueErroredGradePushes(courseUUID: UUID, on db: Database) async throws {
    let resultKeys = try await courseStudentResultIDs(courseUUID: courseUUID, on: db)
    let results =
        resultKeys.isEmpty
        ? []
        : try await APIResult.query(on: db)
            .filter(\.$submissionID ~~ resultKeys)
            .all()
    try await requeueForImmediateSync(
        results.filter { ($0.brightspaceSyncError ?? "").isEmpty == false }, on: db)
    // Errored override-only pushes (no-submission students) live on the
    // override row, not a result row — re-queue those too.
    let setupIDs = try await courseSetupIDs(courseUUID: courseUUID, on: db)
    let overrides =
        setupIDs.isEmpty
        ? []
        : try await APIGradeOverride.query(on: db)
            .filter(\.$testSetupID ~~ setupIDs)
            .all()
    try await requeueForImmediateSync(
        overrides.filter { ($0.brightspaceSyncError ?? "").isEmpty == false }, on: db)
    // Errored grade CLEARS (queued removals) are re-queued too — nothing
    // else touches `brightspace_grade_clears` after a terminal failure, so
    // before this an errored clear lingered forever with an error nobody
    // could see (#1105).
    let clears =
        setupIDs.isEmpty
        ? []
        : try await APIBrightSpaceGradeClear.query(on: db)
            .filter(\.$testSetupID ~~ setupIDs)
            .all()
    try await requeueForImmediateSync(
        clears.filter { ($0.brightspaceSyncError ?? "").isEmpty == false }, on: db)
}

/// Submission IDs (used as result-query keys) for all student submissions
/// in the active course's test setups.
private func courseStudentResultIDs(courseUUID: UUID, on db: Database) async throws -> [String] {
    let setupIDs = try await courseSetupIDs(courseUUID: courseUUID, on: db)
    guard !setupIDs.isEmpty else { return [] }
    return try await APISubmission.query(on: db)
        .filter(\.$testSetupID ~~ setupIDs)
        .filter(\.$kind == APISubmission.Kind.student)
        .all()
        .compactMap(\.id)
}

/// Distinct test setup IDs for the active course's assignments.  Used to
/// scope override-row queries (override-only grade pushes) by course.
private func courseSetupIDs(courseUUID: UUID, on db: Database) async throws -> [String] {
    let setupIDs = try await APIAssignment.query(on: db)
        .filter(\.$courseID == courseUUID)
        .all()
        .map(\.testSetupID)
    return Array(Set(setupIDs))
}

/// Starts a grade-sync sweep in the background and returns immediately, so a
/// manual "Sync now" / "Push all" click never holds the HTTP request open for
/// the duration of every D2L push — a large class is dozens of sequential
/// round-trips, which would otherwise risk a reverse-proxy timeout and leave the
/// instructor staring at a spinner. The rows are already flagged pending by the
/// caller (a fast local write), so even if this sweep does not run the
/// 60-second periodic monitor picks them up. Uses `application.db` (NOT a
/// request's `db`, which is request-scoped) since the sweep outlives the
/// request, and bypasses the debounce so every pending row pushes immediately.
/// Failures are recorded per-row by the sweep itself; a sweep-level throw is
/// logged (it used to be silently swallowed, #1117). No-op when BrightSpace
/// isn't configured.
///
/// The task belongs to `application.backgroundWork`, which cancels and awaits
/// it at shutdown. It used to be a bare `Task` that could still be using the
/// database after Fluent closed it (#1923).
func launchBackgroundBrightSpaceSweep(_ application: Application) async {
    guard let app = application.brightSpaceAppCredentials else { return }
    let debounce = application.brightSpaceSyncConfig?.debounceSecs ?? app.debounceSecs
    await application.backgroundWork.start {
        await runManualBrightSpaceSweep(application) {
            // Each course resolves its designated identity (or the fallback).
            try await sweepBrightSpaceGradeSync(
                on: application.db,
                debounceSecs: debounce,
                resolveClient: { course in
                    try await application.brightSpaceClient(forCourse: course)
                },
                logger: application.logger,
                application: application,
                bypassDebounce: true
            )
        }
    }
}

/// Runs a manual sweep only where and when the periodic sweep cannot also be
/// pushing the same rows (#1923). The sweep reads pending rows without claiming
/// them, so an overlap pushes a grade twice and can leave an old grade in LEARN.
///
/// - On another instance's lease, it does not run: the leader's next periodic
///   sweep pushes the requeued rows, which the caller back-dated past the
///   debounce.
/// - While a sweep holds this process's slot, it does not run either, for the
///   same reason: the lease cannot tell two sweeps of one instance apart.
///
/// Separate from `launchBackgroundBrightSpaceSweep` so a test can pass its own
/// sweep and observe whether it ran.
func runManualBrightSpaceSweep(
    _ application: Application,
    sweep: () async throws -> Int
) async {
    do {
        guard try await application.brightSpaceGradeSyncMonitor.acquireLease(application: application)
        else {
            application.logger.info(
                "BrightSpace manual sweep not run: another instance holds the grade-sync lease, and its next sweep pushes the requeued rows"
            )
            return
        }
        guard try await application.brightSpaceGradeSyncSlot.runIfFree(sweep) != nil else {
            application.logger.info(
                "BrightSpace manual sweep not run: a sweep is already running in this process, and the next periodic sweep pushes the requeued rows"
            )
            return
        }
    } catch is CancellationError {
        // Stopped by the shutdown drain between pushes: not a failure.
    } catch {
        application.logger.warning("BrightSpace background sweep failed: \(error)")
    }
}
