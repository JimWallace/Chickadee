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
    guard submissionMetric(from: outcomes) != nil,
        let setup = try await APITestSetup.find(testSetupID, on: db)
    else { return }
    try await recordLeaderboardEntry(
        setup: setup, userID: userID, submissionID: submissionID, outcomes: outcomes, reachedAt: Date(), on: db)
}

/// `recordLeaderboardEntry(testSetupID:…)` for a caller that has already
/// loaded the setup: the result path reads it once for every effect.
///
/// `reachedAt` is when the student reached this metric: now, for a result
/// landing at ingest; the submission's time, for the repair
/// (`repairLeaderboardEntries`), which writes a row late and must not lose
/// the student a tie for it. Ties rank the earlier `reachedAt` first.
///
/// These are the ranking gates, and the repair goes through them too, so a
/// new gate added here holds for both.
///
/// Every write only RAISES a row, in one conditional statement
/// (`writeBestSoFar`), so results that land at the same moment cannot undo
/// each other and the order they land in does not matter. The record is
/// offered every time rather than only when the row moved: it compares
/// against the class best itself, and a record that a failed write left
/// behind catches up on the next result.
func recordLeaderboardEntry(
    setup: APITestSetup,
    userID: UUID,
    submissionID: String,
    outcomes: [TestOutcome],
    reachedAt: Date,
    on db: any Database
) async throws {
    guard let metric = submissionMetric(from: outcomes),
        let testSetupID = setup.id,
        let activity = setup.decodedManifest()?.activity,
        activity.kind.aggregation == .leaderboard,
        try await courseRole(of: userID, inCourse: setup.courseID, db: db) == .student
    else { return }

    let write = BestMetricWrite(
        testSetupID: testSetupID, userID: userID, submissionID: submissionID, metric: metric, reachedAt: reachedAt)
    if activity.isPerGroup {
        guard
            let session = try await ActivitySessionStore.sessionAtSubmission(
                testSetupID: testSetupID, userID: userID, submissionID: submissionID, on: db)
        else { return }
        try await recordGroupLeaderboardEntry(write, groupID: session.groupID, on: db)
    } else {
        try await recordCourseLeaderboardEntry(write, on: db)
    }

    try await awardHighestMetricRecords(
        setup: setup, userID: userID, submissionID: submissionID, metric: metric, on: db)
}

/// One student's metric on its way to a leaderboard row.
private struct BestMetricWrite {
    let testSetupID: String
    let userID: UUID
    let submissionID: String
    let metric: Double
    let reachedAt: Date
}

/// The course-wide best-so-far row. Strictly better only: a tie keeps the
/// earlier submission, which is also what keeps a replayed report from moving
/// `reachedAt`.
private func recordCourseLeaderboardEntry(_ write: BestMetricWrite, on db: any Database) async throws {
    let row = APILeaderboardEntry.query(on: db)
        .filter(\.$testSetupID == write.testSetupID)
        .filter(\.$userID == write.userID)
    try await writeBestSoFar(
        raise: {
            try await row.copy()
                .filter(\.$metric < write.metric)
                .set(\.$metric, to: write.metric)
                .set(\.$submissionID, to: write.submissionID)
                .set(\.$reachedAt, to: write.reachedAt)
                .update()
        },
        exists: { try await row.copy().first() != nil },
        insert: {
            try await APILeaderboardEntry(
                testSetupID: write.testSetupID, userID: write.userID, submissionID: write.submissionID,
                metric: write.metric, reachedAt: write.reachedAt
            ).create(on: db)
        })
}

/// The per-group twin of the best-so-far write above: one row per (setup,
/// group, student), so a student who plays in two labs ranks in each.
private func recordGroupLeaderboardEntry(_ write: BestMetricWrite, groupID: UUID, on db: any Database) async throws {
    let row = APIGroupLeaderboardEntry.query(on: db)
        .filter(\.$testSetupID == write.testSetupID)
        .filter(\.$groupID == groupID)
        .filter(\.$userID == write.userID)
    try await writeBestSoFar(
        raise: {
            try await row.copy()
                .filter(\.$metric < write.metric)
                .set(\.$metric, to: write.metric)
                .set(\.$submissionID, to: write.submissionID)
                .set(\.$reachedAt, to: write.reachedAt)
                .update()
        },
        exists: { try await row.copy().first() != nil },
        insert: {
            try await APIGroupLeaderboardEntry(
                testSetupID: write.testSetupID, groupID: groupID, userID: write.userID,
                submissionID: write.submissionID, metric: write.metric, reachedAt: write.reachedAt
            ).create(on: db)
        })
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
