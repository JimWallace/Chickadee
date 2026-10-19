// APIServer/Services/LeaderboardEntries.swift
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
/// For an activity that runs per group (docs/lab-groups.md), the row goes to
/// `group_leaderboard_entries`, under the group of the session the student had
/// joined when they submitted. A submission made with no such session open
/// grades and does not rank: the board froze when the session closed
/// (maintainer decision 1).
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
    on db: any Database
) async throws {
    guard let metric = submissionMetric(from: outcomes),
        let setup = try await APITestSetup.find(testSetupID, on: db),
        let activity = setup.decodedManifest()?.activity,
        activity.kind.aggregation == .leaderboard,
        try await courseRole(of: userID, inCourse: setup.courseID, db: db) == .student
    else { return }

    if activity.isPerGroup {
        guard
            let session = try await ActivitySessionStore.sessionAtSubmission(
                testSetupID: testSetupID, userID: userID, submissionID: submissionID, on: db)
        else { return }
        try await recordGroupLeaderboardEntry(
            testSetupID: testSetupID, groupID: session.groupID, userID: userID, submissionID: submissionID,
            metric: metric, on: db)
    } else {
        let existing = try await APILeaderboardEntry.query(on: db)
            .filter(\.$testSetupID == testSetupID)
            .filter(\.$userID == userID)
            .first()
        if let existing {
            // Strictly better only: a tie keeps the earlier submission, which
            // is also what keeps a replayed report from moving `reachedAt`.
            guard metric > existing.metric else { return }
            existing.metric = metric
            existing.submissionID = submissionID
            existing.reachedAt = Date()
            try await existing.update(on: db)
        } else {
            // Ignore the conflict: two first submissions from one student
            // landing at once, first insert wins. Same shape as
            // `awardImmutableBadge`.
            try await APILeaderboardEntry(
                testSetupID: testSetupID, userID: userID, submissionID: submissionID, metric: metric, reachedAt: Date()
            ).createIgnoringConflict(on: db)
        }
    }

    try await awardHighestMetricRecords(
        setup: setup, userID: userID, submissionID: submissionID, metric: metric, on: db)
}

/// The per-group twin of the best-so-far write above: one row per (setup,
/// group, student), so a student who plays in two labs ranks in each.
private func recordGroupLeaderboardEntry(
    testSetupID: String, groupID: UUID, userID: UUID, submissionID: String, metric: Double, on db: any Database
) async throws {
    let existing = try await APIGroupLeaderboardEntry.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .filter(\.$groupID == groupID)
        .filter(\.$userID == userID)
        .first()
    if let existing {
        guard metric > existing.metric else { return }
        existing.metric = metric
        existing.submissionID = submissionID
        existing.reachedAt = Date()
        try await existing.update(on: db)
    } else {
        try await APIGroupLeaderboardEntry(
            testSetupID: testSetupID, groupID: groupID, userID: userID, submissionID: submissionID, metric: metric,
            reachedAt: Date()
        ).createIgnoringConflict(on: db)
    }
}

/// The activity's ranking, best first; ties rank the earlier row first. With
/// `groupID`, one lab group's ranking (docs/lab-groups.md), read from
/// `group_leaderboard_entries` and returned in the same shape, unsaved, so
/// the board builds one way.
///
/// Reads the materialised rows rather than the stored collections, which is
/// the whole point of materialising them.
func leaderboardEntries(
    testSetupID: String, groupID: UUID? = nil, on db: any Database
) async throws -> [APILeaderboardEntry] {
    guard let groupID else {
        return try await APILeaderboardEntry.query(on: db)
            .filter(\.$testSetupID == testSetupID)
            .sort(\.$metric, .descending)
            .sort(\.$reachedAt, .ascending)
            .all()
    }
    return try await APIGroupLeaderboardEntry.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .filter(\.$groupID == groupID)
        .sort(\.$metric, .descending)
        .sort(\.$reachedAt, .ascending)
        .all()
        .map {
            APILeaderboardEntry(
                testSetupID: $0.testSetupID, userID: $0.userID, submissionID: $0.submissionID, metric: $0.metric,
                reachedAt: $0.reachedAt ?? Date())
        }
}
