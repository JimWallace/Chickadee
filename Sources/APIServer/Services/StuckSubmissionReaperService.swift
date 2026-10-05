// APIServer/Services/StuckSubmissionReaperService.swift
//
import Core
import Fluent
import Foundation
import Vapor

/// Default age after which an `assigned` submission with no reported result
/// is considered orphaned and returned to the `pending` pool.  Tuned to be
/// well above any plausible legitimate run time: the server-side timeout
/// budget for a single job is `timeLimitSeconds` per test script plus setup
/// download, cache acquire, and make.  Ten minutes leaves comfortable
/// headroom while still unsticking runners that crash or disappear silently.
/// A job that plays opponents runs the suite once per opponent, so it gets
/// one suite budget more per opponent (`pastOpponentAllowance`).
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
    let candidates = try await scoped()
        .field(\.$id)
        .field(\.$workerID)
        .field(\.$assignedAt)
        .field(\.$testSetupID)
        .all()
    let stuck = try await pastOpponentAllowance(candidates, maxAge: maxAge, now: now, on: db)
    guard !stuck.isEmpty else { return 0 }

    try await scoped()
        .filter(\.$id ~~ stuck.compactMap(\.id))
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

/// The candidates that are past their allowance. An ordinary job's allowance
/// is `maxAge`. A job that plays opponents — a round robin or tests-and-code
/// job plays every classmate — runs the whole suite once per opponent
/// (docs/class-activities.md, "Cost"), so its allowance grows by one suite
/// budget per opponent the claim opened a match row for. Without that, a
/// long matrix job in a large class was put back to pending while it still
/// ran, and a second runner played every match again (#2185).
private func pastOpponentAllowance(
    _ candidates: [APISubmission], maxAge: TimeInterval, now: Date, on db: Database
) async throws -> [APISubmission] {
    let ids = candidates.compactMap(\.id)
    guard !ids.isEmpty else { return [] }
    let openRows = try await APIMatchResult.query(on: db)
        .filter(\.$submissionID ~~ ids)
        .filter(\.$completedAt == nil)
        .all()
    let opponentsBySubmission = Dictionary(openRows.map { ($0.submissionID, 1) }, uniquingKeysWith: +)
    guard !opponentsBySubmission.isEmpty else { return candidates }

    let setupIDs = Set(
        candidates.filter { opponentsBySubmission[$0.id ?? ""] != nil }.map(\.testSetupID))
    var budgetBySetup: [String: TimeInterval] = [:]
    for setup in try await APITestSetup.query(on: db).filter(\.$id ~~ Array(setupIDs)).all() {
        if let id = setup.id { budgetBySetup[id] = suiteTimeBudget(setup.decodedManifest()) }
    }
    return candidates.filter { candidate in
        guard let opponents = opponentsBySubmission[candidate.id ?? ""], let assignedAt = candidate.assignedAt
        else { return true }
        let allowance = maxAge + Double(opponents) * (budgetBySetup[candidate.testSetupID] ?? 0)
        return now.timeIntervalSince(assignedAt) >= allowance
    }
}

/// The longest one run of the suite may take: each entry's time limit, or
/// the manifest's default, summed. Zero for a manifest that cannot be read.
func suiteTimeBudget(_ manifest: TestProperties?) -> TimeInterval {
    guard let manifest else { return 0 }
    return manifest.testSuites.reduce(0) { total, entry in
        total + TimeInterval(entry.timeLimitSeconds ?? manifest.timeLimitSeconds)
    }
}

struct StuckSubmissionReaperMonitorKey: StorageKey {
    typealias Value = PeriodicSweepMonitor
}

extension Application {
    var stuckSubmissionReaperMonitor: PeriodicSweepMonitor {
        lazyStored(StuckSubmissionReaperMonitorKey.self) {
            PeriodicSweepMonitor(
                name: "Stuck submission reaper",
                interval: stuckSubmissionSweepInterval,
                minimumInterval: 1
            ) { application in
                _ = try await reapStuckAssignedSubmissions(
                    on: application.db,
                    logger: application.logger
                )
            }
        }
    }
}
