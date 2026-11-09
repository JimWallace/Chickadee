// APIServer/Services/LeaderboardRepair.swift
//
// Rebuilds a class activity's leaderboard rows from the stored results, for a
// result whose leaderboard write failed.
//
// The leaderboard is written at ingest, after the grade is stored, and that
// write is best effort: it must never fail a submission. So when it throws
// (a database pool that timed out while 150 students submitted at once), the
// grade is safe and the student's row is not. Nothing else writes the row, so
// before this the student stayed off the board until they reported a better
// metric, and nothing on the screen said why.
//
// Now a failed write schedules a repair of that assignment
// (`LeaderboardRepairQueue`). The repair reads every student submission's
// stored results and offers each student's best one to the same
// `recordLeaderboardEntry` ingest calls, gates and all. That write only raises
// a row, so the repair can run at any moment and as often as it likes: it adds
// what is missing and changes nothing that is already right. It stamps a row
// with the submission's time, not the repair's, so a late row keeps its place
// in a tie.
//
// COURSE-WIDE BOARDS ONLY. A per-group board ranks a submission under the
// session the student had joined when they made it, and staff can remove a
// student from a session, which deletes their row there on purpose. A student
// who rejoins would make their earlier submissions count again, and a repair
// would bring back the row staff removed. So a per-group board is not
// repaired: a lost write there waits for the student's next better result.
//
// It reads stored collections, which a leaderboard page must never do on a
// poll (the reason the rows are materialised). It runs only after a failed
// write, and repairs that arrive together become one run.

import Core
import Fluent
import Foundation

/// Offers each student's best stored metric to the leaderboard of
/// `testSetupID`, through `recordLeaderboardEntry`. A no-op for an assignment
/// with no course-wide leaderboard activity.
///
/// Ingest offers a result only when its build passed
/// (`ResultIngestEffects.apply`); this applies the same rule. A retest adds a
/// result row to the submission it re-runs, so every result of a submission
/// counts, as each one did when it landed.
func repairLeaderboardEntries(testSetupID: String, on db: any Database) async throws {
    guard let setup = try await APITestSetup.find(testSetupID, on: db),
        let activity = setup.decodedManifest()?.activity,
        activity.kind.aggregation == .leaderboard, !activity.isPerGroup
    else { return }

    let submissions = try await APISubmission.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .filter(\.$kind == APISubmission.Kind.student)
        .field(\.$id)
        .field(\.$userID)
        .field(\.$submittedAt)
        .all()
    let resultsBySubmission = try await allResultsBySubmissionID(for: submissions.compactMap(\.id), on: db)
    let collections = try await collectionJSONByResultID(
        for: resultsBySubmission.values.flatMap { $0.compactMap(\.id) }, on: db)

    var best: [UUID: RepairOffer] = [:]
    for submission in submissions {
        guard let submissionID = submission.id, let userID = submission.userID else { continue }
        for result in resultsBySubmission[submissionID] ?? [] {
            guard let resultID = result.id, let json = collections[resultID],
                let collection = decodedCollection(from: json), collection.buildStatus == .passed,
                let metric = submissionMetric(from: collection.outcomes)
            else { continue }
            let offer = RepairOffer(
                submissionID: submissionID, outcomes: collection.outcomes, metric: metric,
                submittedAt: submission.submittedAt ?? Date())
            if best[userID].map({ offer.beats($0) }) ?? true { best[userID] = offer }
        }
    }

    for (userID, offer) in best {
        try await recordLeaderboardEntry(
            setup: setup, userID: userID, submissionID: offer.submissionID, outcomes: offer.outcomes,
            reachedAt: offer.submittedAt, on: db)
    }
}

/// A student's candidate for the board: one stored result of one submission.
private struct RepairOffer {
    let submissionID: String
    let outcomes: [TestOutcome]
    let metric: Double
    let submittedAt: Date

    /// Better metric first; on a tie the earlier submission, as at ingest.
    func beats(_ other: RepairOffer) -> Bool {
        if metric != other.metric { return metric > other.metric }
        if submittedAt != other.submittedAt { return submittedAt < other.submittedAt }
        return submissionID < other.submissionID
    }
}
