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

@discardableResult
func reapStuckAssignedSubmissions(
    on db: Database,
    logger: Logger,
    maxAge: TimeInterval = stuckSubmissionDefaultMaxAge,
    now: Date = Date()
) async throws -> Int {
    let cutoff = now.addingTimeInterval(-maxAge)
    let stuck = try await APISubmission.query(on: db)
        .filter(\.$status == "assigned")
        .filter(\.$assignedAt <= cutoff)
        .all()

    for submission in stuck {
        let previousWorker = submission.workerID ?? "unknown"
        submission.status = "pending"
        submission.workerID = nil
        submission.assignedAt = nil
        try await submission.save(on: db)
        logger.warning(
            "Reaped stuck submission \(submission.id ?? "<nil>") (was assigned to \(previousWorker)); returned to pending queue"
        )
    }
    return stuck.count
}

final class StuckSubmissionReaperMonitor: @unchecked Sendable {
    // @unchecked Sendable: the only mutable state (`task`) is touched solely
    // from start()/stop() on the app lifecycle (didBoot/shutdown), never
    // concurrently.
    private var task: Task<Void, Never>?
    private let intervalNanoseconds: UInt64
    private let maxAge: TimeInterval

    init(interval: TimeInterval = 60, maxAge: TimeInterval = stuckSubmissionDefaultMaxAge) {
        intervalNanoseconds = UInt64(max(interval, 1) * 1_000_000_000)
        self.maxAge = maxAge
    }

    func start(application: Application) {
        guard task == nil else { return }
        task = Task {
            while !Task.isCancelled {
                do {
                    _ = try await reapStuckAssignedSubmissions(
                        on: application.db,
                        logger: application.logger,
                        maxAge: maxAge
                    )
                } catch {
                    application.logger.error(
                        "Stuck submission reaper sweep failed: \(error.localizedDescription)"
                    )
                }

                do {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
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

struct StuckSubmissionReaperMonitorKey: StorageKey {
    typealias Value = StuckSubmissionReaperMonitor
}

struct StuckSubmissionReaperLifecycleHandler: LifecycleHandler {
    func didBoot(_ application: Application) throws {
        Task {
            do {
                _ = try await reapStuckAssignedSubmissions(
                    on: application.db,
                    logger: application.logger
                )
            } catch {
                application.logger.error(
                    "Initial stuck submission sweep failed: \(error.localizedDescription)"
                )
            }
        }
        application.stuckSubmissionReaperMonitor.start(application: application)
    }

    func shutdown(_ application: Application) {
        application.stuckSubmissionReaperMonitor.stop()
    }
}

extension Application {
    var stuckSubmissionReaperMonitor: StuckSubmissionReaperMonitor {
        get {
            if let existing = storage[StuckSubmissionReaperMonitorKey.self] { return existing }
            let created = StuckSubmissionReaperMonitor()
            storage[StuckSubmissionReaperMonitorKey.self] = created
            return created
        }
        set {
            storage[StuckSubmissionReaperMonitorKey.self] = newValue
        }
    }
}
