import Fluent
import Foundation
import Vapor

/// Default age after which an `assigned` submission with no reported result
/// is considered orphaned and returned to the `pending` pool.  Tuned to be
/// well above any plausible legitimate run time: the server-side timeout
/// budget for a single job is `timeLimitSeconds` per test script plus setup
/// download, cache acquire, and make.  Ten minutes leaves comfortable
/// headroom while still unsticking runners that crash or disappear silently.
private let stuckSubmissionDefaultMaxAge: TimeInterval = 10 * 60

/// Sweep every minute so a crashed runner's jobs return to the queue quickly.
private let stuckSubmissionSweepInterval: TimeInterval = 60

@discardableResult
func reapStuckAssignedSubmissions(
    on db: Database,
    logger: Logger,
    maxAge: TimeInterval = stuckSubmissionDefaultMaxAge,
    now: Date = Date()
) async throws -> Int {
    let cutoff = now.addingTimeInterval(-maxAge)

    func scoped() -> QueryBuilder<APISubmission> {
        APISubmission.query(on: db)
            .filter(\.$status == SubmissionStatus.assigned.rawValue)
            .filter(\.$assignedAt <= cutoff)
    }

    // Read (id, worker) pairs first so the per-submission warning keeps naming
    // the runner that dropped the job, then flip the whole set back to pending
    // in ONE bulk UPDATE (same pattern as bulkFlipStudentSubmissionsToPending)
    // instead of a save per row.  After a fleet-wide runner crash near a
    // deadline every in-flight job ages out in the same sweep; the old
    // per-row loop turned that into N sequential round-trips every 60 s.
    // A row newly aging past the cutoff between the read and the UPDATE is
    // flipped without its log line and gets logged by the next sweep — benign.
    let stuck = try await scoped()
        .field(\.$id)
        .field(\.$workerID)
        .all()
    guard !stuck.isEmpty else { return 0 }

    try await scoped()
        .set(\.$status, to: SubmissionStatus.pending.rawValue)
        .set(\.$workerID, to: nil)
        .set(\.$assignedAt, to: nil)
        .update()

    for submission in stuck {
        // Submission id in metadata only — message text reaches the admin
        // query_logs buffer unredacted (compliance audit F-1).
        logger.warning(
            "Reaped stuck submission (was assigned to \(submission.workerID ?? "unknown")); returned to pending queue",
            metadata: ["submission_id": .string(submission.id ?? "<nil>")]
        )
    }
    return stuck.count
}

struct StuckSubmissionReaperMonitorKey: StorageKey {
    typealias Value = PeriodicSweepMonitor
}

extension Application {
    var stuckSubmissionReaperMonitor: PeriodicSweepMonitor {
        get {
            if let existing = storage[StuckSubmissionReaperMonitorKey.self] { return existing }
            let created = PeriodicSweepMonitor(
                name: "Stuck submission reaper",
                interval: stuckSubmissionSweepInterval,
                minimumInterval: 1,
                runImmediately: true
            ) { application in
                _ = try await reapStuckAssignedSubmissions(
                    on: application.db,
                    logger: application.logger
                )
            }
            storage[StuckSubmissionReaperMonitorKey.self] = created
            return created
        }
        set {
            storage[StuckSubmissionReaperMonitorKey.self] = newValue
        }
    }
}
