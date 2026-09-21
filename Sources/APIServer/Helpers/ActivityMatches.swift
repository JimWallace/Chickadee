// APIServer/Helpers/ActivityMatches.swift
//
// The server half of a king-of-the-hill activity (docs/class-activities.md,
// "King of the hill"): choosing a challenger's opponent when its job is
// built, and rewriting the hill when its result lands.
//
// The two halves talk through `match_results`. The claim path OPENS a row
// naming the opponent the job will play; the result path COMPLETES it and
// decides the hill from what the row says the challenger played — never
// from the champion of the moment, which may have changed while the job was
// out. Wired at both ingest paths beside `recordLeaderboardEntry`, for the
// reason that helper records.

import Core
import Fluent
import Foundation
import Vapor

/// The opponent a challenger plays, as the claim path chose it.
struct ChosenOpponent {
    /// The champion's submission, or nil when the bot (or nobody) holds the hill.
    let champion: APISubmission?
    /// `JobOpponent.submissionIdentity` / `supportFileIdentity` / `noOpponentIdentity`.
    let identity: String
}

/// Who a challenger plays right now: the current champion's submission,
/// unless the challenger IS that submission (a re-test of the champion plays
/// the bot, never itself), else the bundled bot, else nobody.
///
/// A champion who RESUBMITS does play their own earlier entry: beating it
/// moves the hill's submission forward, losing to it changes nothing.
func chooseOpponent(
    for submission: APISubmission, activity: ClassActivity, on db: Database
) async throws -> ChosenOpponent {
    let bot = ChosenOpponent(
        champion: nil,
        identity: activity.opponentFile.map(JobOpponent.supportFileIdentity)
            ?? JobOpponent.noOpponentIdentity)
    guard activity.kind.opponentSource == .champion,
        let champion = try await APIActivityChampion.query(on: db)
            .filter(\.$testSetupID == submission.testSetupID)
            .first(),
        champion.submissionID != submission.id,
        let championSubmission = try await APISubmission.find(champion.submissionID, on: db)
    else { return bot }
    return ChosenOpponent(
        champion: championSubmission,
        identity: JobOpponent.submissionIdentity(champion.submissionID))
}

/// Opens (or reopens, on a re-test) the match row for this job. One row per
/// (submission, opponent identity): a re-test against the same opponent
/// reuses it, so a replayed report of the earlier run can no longer complete
/// a row the re-test owns.
func openMatch(
    testSetupID: String, submissionID: String, opponent: ChosenOpponent, seed: String, on db: Database
) async throws {
    let existing = try await APIMatchResult.query(on: db)
        .filter(\.$submissionID == submissionID)
        .filter(\.$opponentIdentity == opponent.identity)
        .first()
    if let existing {
        existing.score = nil
        existing.metric = nil
        existing.won = nil
        existing.completedAt = nil
        existing.createdAt = Date()
        existing.seed = seed
        try await existing.update(on: db)
    } else {
        // Ignore the conflict: two claims of one submission at once, first
        // insert wins — the same shape as `awardImmutableBadge`.
        try? await APIMatchResult(
            testSetupID: testSetupID, submissionID: submissionID,
            opponentSubmissionID: opponent.champion?.id, opponentIdentity: opponent.identity,
            seed: seed, createdAt: Date()
        ).save(on: db)
    }
}

/// The match entry of a collection: the outcome with the highest reported
/// `metric`. The verdict is the script's exit code — the challenger won when
/// that entry PASSED — and `score` is its credit. Nil when no outcome reports
/// a metric, which a match script that wants a lost run off the board does
/// on purpose: no metric, no win.
func matchOutcome(from outcomes: [TestOutcome]) -> TestOutcome? {
    outcomes.filter { $0.metric != nil }.max { ($0.metric ?? 0) < ($1.metric ?? 0) }
}

/// Completes this submission's open match and rewrites the hill.
///
/// The rules, each pinned by `ActivityChampionTests`:
///
/// - A **replayed** report finds no open row and does nothing.
/// - A **re-test of the champion's own submission** never moves the hill,
///   whatever it scores: the row it played was against the bot.
/// - The challenger **takes the hill** when the match entry passed AND the
///   opponent it played is still the hill's holder (the current champion's
///   submission, or the bot / nobody while no student holds it). A win
///   against a champion who has since been replaced crowns nobody: the
///   student beat the wrong opponent, and a re-test plays the right one.
/// - A **champion beating their own earlier entry** moves the hill's
///   submission forward and keeps the streak.
/// - A **loss to the current champion** counts one defence.
/// - Only a `.student` in the setup's own course can hold the hill, so a
///   staff validation run completes its row and changes nothing.
func recordActivityMatch(
    testSetupID: String,
    userID: UUID,
    submissionID: String,
    outcomes: [TestOutcome],
    on db: Database
) async throws {
    guard let setup = try await APITestSetup.find(testSetupID, on: db),
        let activity = setup.decodedManifest()?.activity,
        activity.kind.opponentSource == .champion,
        let match = try await APIMatchResult.query(on: db)
            .filter(\.$submissionID == submissionID)
            .filter(\.$completedAt == nil)
            .sort(\.$createdAt, .descending)
            .first()
    else { return }

    let entry = matchOutcome(from: outcomes)
    let won = entry?.status == .pass
    match.score = entry?.score
    match.metric = entry?.metric
    match.won = won
    match.completedAt = Date()
    try await match.update(on: db)

    guard try await courseRole(of: userID, inCourse: setup.courseID, db: db) == .student else { return }
    let current = try await APIActivityChampion.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .first()
    // The champion's own re-test played the bot; the hill does not move.
    if current?.submissionID == submissionID { return }
    // What the job played must still be what holds the hill.
    let playedTheHill = match.opponentSubmissionID == current?.submissionID
    guard playedTheHill else { return }

    if won {
        if let current, current.userID == userID {
            current.submissionID = submissionID
            try await current.update(on: db)
        } else if let current {
            current.userID = userID
            current.submissionID = submissionID
            current.crownedAt = Date()
            current.defences = 0
            try await current.update(on: db)
        } else {
            try? await APIActivityChampion(
                testSetupID: testSetupID, userID: userID, submissionID: submissionID, crownedAt: Date()
            ).save(on: db)
        }
        try await awardChampionRecords(setup: setup, userID: userID, submissionID: submissionID, on: db)
    } else if let current, current.userID != userID {
        current.defences += 1
        try await current.update(on: db)
    }
}

/// The hill's current holder, for the leaderboard page; nil when the bot or
/// nobody holds it.
func currentChampion(testSetupID: String, on db: Database) async throws -> APIActivityChampion? {
    try await APIActivityChampion.query(on: db)
        .filter(\.$testSetupID == testSetupID)
        .first()
}
