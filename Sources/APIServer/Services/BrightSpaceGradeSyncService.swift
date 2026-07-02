// APIServer/Services/BrightSpaceGradeSyncService.swift
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
    let ids = rows.map(\.brightspaceSyncRowID).joined(separator: ", ")
    logger.warning(
        "BrightSpace grade sync \(retryable ? "transient" : "terminal") failure for row(s) \(ids): \(error)")
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
