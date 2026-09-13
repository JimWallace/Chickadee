// APIServer/Helpers/LeaderboardEntries.swift
//
// Materialises a class activity's leaderboard at result ingest — one row per
// (assignment, student) carrying the best `metric` reported so far — and
// awards the `highestMetric` class record on the same event. Called from every
// result ingest path (the worker report and the browser result routes) beside
// `recordClassItemCoverage`, and for the same reason it is wired at BOTH: an
// accumulator wired at one path reads as the whole class when it is only the
// half graded on one substrate (audit A2).
//
// See docs/class-activities.md.

import Core
import Fluent
import Foundation
import Vapor

/// The submission-level ranking number: the highest `metric` any outcome in
/// the collection reported, or nil when none did.
///
/// A leaderboard activity's suite carries one measuring entry in practice,
/// but nothing enforces that, and "highest" is the only rule consistent with
/// the row it feeds — the leaderboard is a best-so-far ranking, and a second
/// measuring script can only raise a student's best, never lower it.
func submissionMetric(from outcomes: [TestOutcome]) -> Double? {
    outcomes.compactMap(\.metric).max()
}

/// Records this submission's metric on the activity's leaderboard when it is
/// the student's best so far, and awards the `highestMetric` class record
/// when it beats the class. A no-op for an assignment with no leaderboard
/// activity, for a collection reporting no metric, and for a submitter who is
/// not a `.student` in the setup's own course (staff test runs must not rank).
///
/// Safe to call repeatedly for the same submission: a re-test or a replayed
/// report re-reads the same metric and finds nothing better to write.
///
/// Deliberately NOT gated on the submission's grade. The metric is what the
/// script chose to measure, and a run that fails a correctness gate yet
/// reports a metric is the script's own business — a script that wants a
/// failing run off the board reports no metric on failure.
func recordLeaderboardEntry(
    testSetupID: String,
    userID: UUID,
    submissionID: String,
    outcomes: [TestOutcome],
    on db: Database
) async throws {
    guard let metric = submissionMetric(from: outcomes),
        let setup = try await APITestSetup.find(testSetupID, on: db),
        setup.decodedManifest()?.activity?.kind.aggregatesToLeaderboard == true,
        try await courseRole(of: userID, inCourse: setup.courseID, db: db) == .student
    else { return }

    let existing = try await APILeaderboardEntry.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .filter(\.$userID == userID)
        .first()
    if let existing {
        // Strictly better only: a tie keeps the earlier submission, which is
        // also what keeps a replayed report from moving `reachedAt`.
        guard metric > existing.metric else { return }
        existing.metric = metric
        existing.submissionID = submissionID
        existing.reachedAt = Date()
        try await existing.update(on: db)
    } else {
        let row = APILeaderboardEntry(
            testSetupID: testSetupID, userID: userID, submissionID: submissionID,
            metric: metric, reachedAt: Date())
        // Ignore the conflict: two first submissions from one student landing
        // at once, first insert wins. Same shape as `awardImmutableBadge`.
        try? await row.save(on: db)
    }

    try await awardHighestMetricRecords(
        setup: setup, userID: userID, submissionID: submissionID, metric: metric, on: db)
}

/// The activity's ranking, best first; ties rank the earlier row first.
///
/// Reads the materialised rows rather than the stored collections, which is
/// the whole point of materialising them.
func leaderboardEntries(
    testSetupID: String, on db: Database
) async throws -> [APILeaderboardEntry] {
    try await APILeaderboardEntry.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .sort(\.$metric, .descending)
        .sort(\.$reachedAt, .ascending)
        .all()
}
