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
    let stuck = try await APISubmission.query(on: db)
        .filter(\.$status == SubmissionStatus.assigned.rawValue)
        .filter(\.$assignedAt <= cutoff)
        .all()

    for submission in stuck {
        let previousWorker = submission.workerID ?? "unknown"
        submission.setStatus(.pending)
        submission.workerID = nil
        submission.assignedAt = nil
        try await submission.save(on: db)
        logger.warning(
            "Reaped stuck submission \(submission.id ?? "<nil>") (was assigned to \(previousWorker)); returned to pending queue"
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
